#!/home/bingos/perl5.10.0/bin/perl

use strict;
use warnings;
use if $^O eq 'linux', 'POE::Kernel'=> { loop => 'POE::XS::Loop::EPoll' };
use if $^O ne 'linux', 'POE::Kernel' => { loop => 'POE::XS::Loop::Poll' };
use POE qw(Component::IRC::State Component::EasyDBI);
use POE::Component::IRC::Plugin::PlugMan;
use Config::Tiny;
use Getopt::Long;
use vars qw($VERSION);

$VERSION = '0.9';

my $usage = "Usage: $0 [option]\n\n--nick <nickname>\n--moduledir <pathtodir>\n--config <configfile>\n";

my $nickname;
my $config = 'GumbyNET.cfg';
my $dsn;
my $user;
my $pass;
my $mdir;
my $owner;
my $httpd;
my $console = 9090;
my $bouncer = 9091;

GetOptions( 
	"nick=s" => \$nickname,
	"moduledir=s" => \$mdir,
	"config=s" => \$config,
);

unless ( $nickname ) {
   die "No nickname specified\n$usage";
}

unless ( -e $config ) {
   die "Config file $config does not exist.\n$usage";
}

if ( $mdir and not -e "$mdir/PlugMan.pm" ) {
   die "Problem with specified moduledir: $mdir\n$usage";
}

unless ( $mdir ) {
  $mdir = './lib';
}
push( @INC, $mdir );
if ( $@ ) {
  print "$@\n";
  die;
}

warn "Using: ", $poe_kernel->poe_kernel_loop, "\n";

=for comment 
open(CONFIG,"<$config") or die "Problem opening config file $config : $!\n";

while (<CONFIG>) {
   chomp;
   SWITCH: {
	if ( /\s*DSN\s*=\s*(.+)$/i ) { $dsn = $1; last SWITCH; }
	if ( /\s*USER\s*=\s*(.+)$/i ) { $user = $1; last SWITCH; }
	if ( /\s*PASS\s*=\s*(.+)$/i ) { $pass = $1; last SWITCH; }
	if ( /\s*OWNER\s*=\s*(.+)$/i ) { $owner = $1; last SWITCH; }
	if ( /\s*CONSOLE\s*=\s*(\d+)$/i ) { $console = $1; last SWITCH; }
	if ( /\s*BOUNCER\s*=\s*(\d+)$/i ) { $bouncer = $1; last SWITCH; }
   }
}
close(CONFIG);
=cut

my $Config = Config::Tiny->read( $config ) or die "$!\n";

$dsn	 = $Config->{_}->{DSN}     if $Config->{_}->{DSN};
$user	 = $Config->{_}->{USER}    if $Config->{_}->{USER};
$pass	 = $Config->{_}->{PASS}    if $Config->{_}->{PASS};
$owner   = $Config->{_}->{OWNER}   if $Config->{_}->{OWNER};
$console = $Config->{_}->{CONSOLE} if $Config->{_}->{CONSOLE};
$bouncer = $Config->{_}->{BOUNCER} if $Config->{_}->{BOUNCER};
$httpd   = $Config->{_}->{HTTPD}   if $Config->{_}->{HTTPD};

unless ( $dsn ) {
  die "You must specify DSN, USER and PASS in the config file\n";
}

my $irc = POE::Component::IRC::State->spawn( AwayPoll => 0 );

POE::Component::EasyDBI->new(
	alias => 'dbi',
	dsn => $dsn,
	username => $user,
	password => $pass,
);


POE::Session->create(
	inline_states => {
		_start   	 => \&bot_start,
		irc_disconnected => \&bot_disconnect,
        	irc_error        => \&bot_disconnect,
        	irc_socketerr    => \&bot_disconnect,
	        connect  	 => \&bot_connect,
	},
	package_states => [
	  'main' => [ qw(irc_plugin_add irc_001 irc_433 bot_got_config bot_got_channels
		      bot_get_back_nick) ],
	],
	options => { trace => 0 },

	heap => { NickName => $nickname,
		  owner => $owner,
		  console => $console,
		  bouncer => $bouncer,
		},
);

$poe_kernel->run();
exit 0;

##############################
# IRC related event handlers #
##############################

sub bot_start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  $heap->{start} = time();

  $irc->yield( 'register' => 'all' );

  # Construct botver
  $heap->{botver} = "GumbyNET-" . $VERSION . ' poco-irc(' . $POE::Component::IRC::VERSION . ') poe(' . $POE::VERSION . ') easydbi(' . $POE::Component::EasyDBI::VERSION . ') ' . sprintf("Perl(%vd)",$^V);

  # Add PlugMan
  $irc->plugin_add( 'PlugMan', POE::Component::IRC::Plugin::PlugMan->new( botowner => $heap->{owner} ) );

  $kernel->post ( 'dbi' => hash => {
			sql => 'select * from BotConfig where NickName = ?',
			placeholders => [ $heap->{NickName} ],
			event => 'bot_got_config',
  } );

}

sub irc_plugin_add {
  my ($kernel,$heap,$desc,$plugin) = @_[KERNEL,HEAP,ARG0,ARG1];

  if ( $desc eq 'PlugMan' ) {
    print STDERR "Loaded 'PlugMan' plugin\nLoading other plugins\n";
    $plugin->load( 'Connector', 'POE::Component::IRC::Plugin::Connector' );
    $plugin->load( 'Trust2', 'Trust2', dbi => 'dbi', botnick => $heap->{NickName}, botowner => $heap->{owner} );
    #$plugin->load( 'Logger', 'Logger', dbi => 'dbi', session => $_[SESSION]->ID(), botnick => $heap->{NickName} );
    #$plugin->load( 'Debug', 'Debug', file => './output/' . $heap->{NickName} . '.debug' );
    $plugin->load( 'CTCP', 'CTCP', botver => $heap->{botver}, info => $heap->{NickName} );
    $plugin->load( 'DNS', 'POE::Component::IRC::Plugin::QueryDNS' );
    $plugin->load( 'CoreList', 'POE::Component::IRC::Plugin::CoreList', 'command', 'core' );
    $plugin->load( 'Console', 'Console', bindport => $heap->{console} );
    $plugin->load( 'Bouncer', 'Bouncer', bindport => $heap->{bouncer}, botowner => $heap->{owner} );
    #$plugin->load( 'RSS', 'RSS' );
    #$plugin->load( 'GitHub', 'GitHub', bindport => $httpd, dbi => 'dbi' ) if $httpd;
    #$plugin->load( 'Shorten', 'Shorten', ignored_nicks => [ qw(purl nopaste workbench shorten chansen) ] );
  } else {
    print STDERR "PlugMan loaded '$desc'\n";
  }
}

sub bot_connect {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    $heap->{RealNick} = $heap->{NickName};

    my (%parameters) = ( Nick => $heap->{NickName},
			 Server => $heap->{ServerName},
			 Port => $heap->{ServerPort},
			 Username => $heap->{UserName},
			 Ircname => $heap->{IRCName},
			 PartFix => 1,
			 Raw => 1,
			);
    $irc->yield( connect => \%parameters );
}

sub irc_001 {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    if ( $heap->{Umode} ) {
	$irc->yield( mode => $irc->nick_name() => ( $heap->{Umode} =~ /^(\+|-)/ ? $heap->{Umode} : '+' . $heap->{Umode} ) );
    }

    my ($plugman) = $irc->plugin_get( 'PlugMan' );
    if ( $plugman ) {
      $plugman->load( 'Public', 'Public', botver => $heap->{botver}, start => $heap->{start}, connect => time() );
    }

    $kernel->post ( 'dbi' => arrayhash => {
			sql => 'select Channel from BotChannels where NickName = ?',
			event => 'bot_got_channels',
			placeholders => [ $heap->{NickName} ],
    } );

}

sub bot_disconnect {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    my ($plugman) = $irc->plugin_get( 'PlugMan' );
    if ( $plugman ) {
      $plugman->unload( 'Public' );
    }
}

sub irc_433 {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    my ($nick) = ( split(/ :/,$_[ARG1]) )[0];
    $heap->{RealNick} .= '_';
    $irc->yield( nick => $heap->{RealNick} );
    $kernel->delay ( bot_get_back_nick => 30 );
}

sub bot_get_back_nick {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    $heap->{RealNick} = $heap->{NickName};

    $irc->yield( nick => $heap->{RealNick} );
}

################################
# Database event handlers here #
################################

sub bot_got_config {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};
  my ($context) = $_[ARG0]->{context};

  if ( not defined ( $error ) ) {
    $heap->{UserName} = $result->{IRCUser};
    $heap->{IRCName} = $result->{IRCName};
    $heap->{ServerName} = $result->{IRCServer};
    $heap->{ServerPort} = $result->{IRCPort};
    $heap->{Umode} = $result->{IRCUmode};
    $kernel->yield ( 'connect' );
  }

}

sub bot_got_channels {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};

  if ( not defined ( $error ) ) {
	foreach my $channel ( @{ $result } ) {
	     $irc->yield( join => $channel->{Channel} );
	}
  }
}
