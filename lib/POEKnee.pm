package POEKnee;

use strict;
use warnings;
use POE;
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Component::IRC::Common qw(:ALL);
use vars qw($VERSION);

$VERSION = "1.10";

sub new {
  bless { }, shift;
}

sub PCI_register {
  my ($self,$irc) = @_;
  $self->{irc} = $irc;
  $irc->plugin_register( $self, 'SERVER', qw(public) );
  $self->{session_id} = POE::Session->create(
	object_states => [ 
	   $self => [ qw(_shutdown _start _race_on _run) ],
	],
  )->ID();
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;
  $poe_kernel->call( $self->{session_id} => '_shutdown' );
  delete $self->{irc};
  return 1;
}

sub S_public {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my $channel = ${ $_[1] }->[0];
  my $what = ${ $_[2] };
  my $mapping = $irc->isupport('CASEMAPPING');
  return PCI_EAT_NONE unless u_irc( $channel, $mapping ) eq '#POE';
  my $mynick = $irc->nick_name();
  my ($command) = $what =~ m/^\s*\Q$mynick\E[\:\,\;\.]?\s*(.*)$/i;
  return PCI_EAT_NONE unless $command;
  my @cmd = split /\s+/, $command;
  return PCI_EAT_NONE unless uc( $cmd[0] ) eq 'POEKNEE';
  return PCI_EAT_NONE if $self->{_race_in_progress};
  $poe_kernel->post( $self->{session_id}, '_race_on', $channel );
  return PCI_EAT_NONE;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{_race_in_progress} = 0;
  $self->{session_id} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{session_id}, __PACKAGE__ );
  undef;
}

sub _shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $kernel->alarm_remove_all();
  $kernel->refcount_decrement( $self->{session_id}, __PACKAGE__ );
  undef;
}

sub _race_on {
  my ($kernel,$self,$channel) = @_[KERNEL,OBJECT,ARG0];
  $self->{_race_in_progress} = 1;
  $self->{_distance} = 5;
  my $irc = $self->{irc};
  my @channel_list = $irc->channel_list($channel);
  srand( time() * scalar @channel_list );
  my $seed = 5;
  foreach my $nick ( @channel_list ) {
     #my $nick_modes = $irc->nick_channel_modes($channel,$nick);
     #$seed += rand(3) if $nick_modes =~ /o/;
     #$seed += rand(2) if $nick_modes =~ /h/;
     #$seed += rand(1) if $nick_modes =~ /v/;
     $kernel->delay_add( '_run', rand($seed), $nick, $channel, $seed, 1 );
  }
  $irc->yield('privmsg', $channel, 'POE::Knee Race is on! ' . scalar @channel_list . ' ponies over ' . $self->{_distance} . ' stages.' );
  undef;
}

sub _run {
  my ($kernel,$self,$nick,$channel,$seed,$stage) = @_[KERNEL,OBJECT,ARG0..ARG3];
  $stage++;
  #$self->{irc}->yield( 'privmsg', $channel, "$nick reached stage " . ++$stage );
  if ( $stage > $self->{_distance} ) {
	# Stop the race
	$kernel->alarm_remove_all();
	$self->{irc}->yield( 'privmsg', $channel, "$nick! Won the POE::Knee race!" );
  	$self->{_race_in_progress} = 0;
	return;
  }
  srand( time() );
  $kernel->delay_add( '_run', rand($seed), $nick, $channel, $seed, $stage );
  undef;
}