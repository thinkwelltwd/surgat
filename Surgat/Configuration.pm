package Surgat::Configuration;

use strict;
use Getopt::Long;

my %types_map = ('string' => 's', 'num' => 'i', 'file' => 's', 'user' => 's', group=>'s');

my @options = (
    {long=>'help', text => 'Show this help and exit'},
    {long=>'listen-host', arg => 'string', text => 'Hostname for listening socket', default => '127.0.0.1', section => 'Proxy'},
    {long=>'listen-port', arg => 'num', text => 'Port for listening socket', default => 10025, section => 'Proxy'},
    {long=>'relay-host', arg => 'string', text => 'Hostname for relay server', default => '127.0.0.1', section => 'Proxy'},
    {long=>'relay-port', arg => 'num', text => 'Port relay server listens on', default => 10026, section => 'Proxy'},
    {long=>'configpath', short => 'C', arg => 'string', text => 'Location of default, system-wide rules (file or directory)', 
     default=>'/usr/share/spamassassin', section => 'Spamassassin'},
    {long=>'siteconfigpath', arg => 'string', text => 'Site specific configuration file/directory', section => 'Spamassassin'},
    {long=>'log-level', arg => 'num', text=>'Logging level to use', default=>2, section=>'Logging'},
    {long=>'syslog', short=>'s', negate=>1, text=>'Enable syslog?', default=>1, section=>'Logging'},
    {long=>'syslog-facility', text=>'Syslog facility for logging', default=>'mail', arg=>'string', section=>'Logging'},
    {long=>'syslog-ident', text=>'Ident string to use for syslog', default=>'surgat', arg=>'string', section=>'Logging'},
    {long=>'syslog-socket', text=>'Socket for syslog connection', default=>'unix', arg=>'string', section=>'Logging'},
    {long=>'logfile', text=>'File to log into', arg=>'string', section=>'Logging'},
    {long=>'username', short=>'u', text=>'Username to run server as', arg=>'user', default=>'mail', section=>'Server'},
    {long=>'groupname', short=>'g', text=>'Group to run server as', arg=>'group', default=>'mail', section=>'Server'},
    {long=>'children', text=>'Number of server processes to start', arg=>'num', default=>5, section=>'Server'},
    {long=>'max-conn-per-child', text=>'Max connections per-child', arg=>'num', default=>100, section=>'Server'},
    {long=>'daemonize', short=>'d', text=>'Run server as a daemon', default=>0, section=>'Server', negate=>1},
    {long=>'pidfile', text=>'Location of PID file', default=>'/var/run/surgat.pid', arg=>'file', section=>'Server'},
    {long=>'ipv4-only', text=>'Restrict server to IPv4 sockets', default=>1, negate=>1},
    {long=>'paranoid', short=>'P', text=>'Run in paranoid mode', default=>0, section=>'Spamassassin'},
    {long=>'max-size', text=>'Largest message to process via Spamassassin (kB)', default=>1024, arg=>'num', section=>'Spamassassin'},
    {long=>'local-only', text=>'Use only local tests for Spamassassin', default=>0, section=>'Spamassassin'},
    {long=>'sql-config', short=>'q', text=>'Enable SQL scores/settings', default=>0, section=>'Spamassassin'},
    {long=>'sql-setuid', short=>'Q', text=>'Set uid from SQL', default=>0, section=>'Spamassassin'},
    {long=>'nouser-config', short=>'x', text=>'Do not use user config files', default=>0, section=>'Spamassassin'},
    {long=>'create-prefs', short=>'c', negate=>1, text=>'Create user prefs if required', default=>0, section=>'Spamassassin'},
    {long=>'cf', array=>1, text=>'Additional configuration lines', arg=>'string', section=>'Spamassassin'},
    {long=>'version', short=>'v', text=>'Print version and exit'},
    {long=>'helper-home-dir', short=>'H', arg=>'string', section=>'Spamassassin', text=>'Helper home directory', optional=>1},
    {long=>'timeout-sa', arg=>'num', default=>280, text=>'Spamassassin timeout (secs)', section=>'Spamassassin'},
    {long=>'timeout', arg=>'num', default=>300, text=>'Server child timeout', section=>'Server'},
    {long=>'timeout-network', arg=>'num', default=>60, text=>'Server network timeout', section=>'Server'},
    {long=>'logformat', arg=>'string', default=>'%Y-%b-%d %H:%M:%S', text=>'Format for log date/time stamp', section=>'Logging'},
    {long=>'auto-whitelist', default=>0, text=>'Automatically whitelist senders', section=>'Spamassassin'},
    {long=>'debug', default=>'', text=>'Spamassassin Debug', arg=>'string', section=>'Spamassassin'},
    {long=>'lint', text=>'Spamassassin Lint rule check', section=>'Spamassassin'},
);

sub new {
    my $this = shift;
    my $class = ref($this) || $this;
    my $self = {};

    my %options;
    foreach my $opt (@options) {
        next unless ref($opt) eq 'HASH';
        my %opts = %{$opt};
        my $key = make_option_string(\%opts);
        $options{$key} = \@{$self->{$opts{'long'}}} if exists($opts{'array'});
        $options{$key} = \$self->{$opts{'long'}} if ! exists($opts{'array'});
        if (exists($opts{'negate'}) && exists($opts{'short'})) {
            my $key2 = make_option_string(\%opts, 1);
            $options{$key2} = \@{$self->{$opts{'long'}}} if exists($opts{'array'});
            $options{$key2} = \$self->{$opts{'long'}} if ! exists($opts{'array'});
        }
        next unless exists($opts{'default'});
        $self->{$opts{'long'}} = $opts{'default'};
    }

    Getopt::Long::Configure("bundling");
    $self->{'result'} = GetOptions(%options);

#        'allowed-ips|A=s'          => \@{$self->{'allowed-ip'} },
#        'ldap-config!'             => \$self->{'ldap-config'},
  #      'setuid-with-ldap'         => \$self->{'setuid-with-ldap'},
  #      'log-timestamp-fmt:s'      => \$self->{'log-timestamp-fmt'},
  #      'virtual-config-dir=s'     => \$self->{'virtual-config-dir'},

    bless($self, $class);
    return $self;
}

sub config_error {
    my $msg = shift;
    print "\nConfiguration Error:\n  $msg\n";
    exit 0;
}

sub section {
    my ($self, $section) = @_;
    my %rv;

    foreach my $opt (@options) {
        next unless ref($opt) eq 'HASH';
        my %opts = %{$opt};
        next unless (exists($opts{'section'}) && $opts{'section'} eq $section);
        $rv{$opts{'long'}} = $self->{$opts{'long'}};
    }
    return %rv;
}
    
sub sanity_check {
    my $self = shift;

    config_error("Number of child processes cannot be less than 1! [--children]") if $self->{'children'} < 1;
    config_error("You specified a logfile but also syslog?") if ($self->{logfile} && $self->{syslog});
    config_error("You haven't specified any logging? Not a good idea...") if (! $self->{logfile} && ! $self->{syslog});
    if ($self->{'listen-host'} eq $self->{'relay-host'} && $self->{'listen-port'} eq $self->{'relay-port'}) {
        config_error("Local and relay host are the same!");
    }
    if ($self->{'log-level'} < 0) { $self->{'log-level'} = 0; }
    if ($self->{'log-level'} > 4) {
        print "We love your enthusiasm, but log-levels only go as high as 4!\n";
        $self->{'log-level'} = 3;
    }
    if ($self->{'log-level'} == 4 && $self->{'daemonize'}) {
        print "**\n** At log level 4, the server normally does not run as a daemon.\n**\n";
        $self->{'daemonize'} = 0;
    }

    foreach my $opt (
        qw(
          configpath
          siteconfigpath
          pidfile
          home_dir_for_helpers
        )
    ) {
        $self->{$opt} = Mail::SpamAssassin::Util::untaint_file_path(
            File::Spec->rel2abs( $self->{$opt} )    # rel2abs taints the new value!
        ) if ( $self->{$opt} );
    }
}

sub log_options {
    my $self = shift;
    return (($self->{'syslog-socket'} || "unix"),
            ($self->{'syslog-facility'} || 'all'));
}

sub server_options {
    my $self = shift;
    return (log_file => 'Sys::Syslog',
            syslog_ident => 'surgat::Server',
            syslog_facility => ($self->{'syslog-facility'} || "mail"),
    );
}

sub print_options {
    my $self = shift;
    print "\n\nCurrent Configuration:\n\n";
    foreach my $k (sort keys %{$self}) {
        next unless $self->{$k};
        if (ref($self->{$k}) eq 'ARRAY') {
            next unless scalar(@{$self->{$k}});
            printf("    %-30s: ", $k);
            my $n = 0;
            foreach $a (@{$self->{$k}}) {
                print ' ' x 36 if $n;
                print $a."\n";
                $n += 1;
            }
        } else {
            printf("    %-30s: %s\n", $k, $self->{$k});
        }
    }
    print "\n";
}

sub make_option_string {
    my ($opts, $ignore_long) = @_;
    my $rv = '';
    if (exists($opts->{'long'}) && ! $ignore_long) {
        $rv .= $opts->{'long'};
        return $rv."!" if exists($opts->{'negate'});
    }
    $rv .= "|" if exists($opts->{'short'}) && length($rv);
    $rv .= $opts->{'short'} if exists($opts->{'short'});
    if (exists($opts->{'arg'})) {
        $rv .= exists($opts->{'optional'}) ? ":" : "=";
        $rv .= $types_map{$opts->{'arg'}};
    }
    return $rv;
}

sub print_configuration_options {
    my %sections;
    
    foreach my $opt (@options) {
        next unless ref($opt) eq 'HASH';
        my %opts = %{$opt};
        my $s = $opts{'section'} || 'General';
        push(@{$sections{$s}}, $opt);
    }

    foreach my $sect (sort(keys(%sections))) {
        print "\n".$sect."\n"."-" x length($sect)."\n";
        foreach my $o (@{$sections{$sect}}) {
            my $line = '    ';
            my %opt = %{$o};
            $line .= "-".$opt{'short'}." " if exists($opt{'short'});
            $line .= "--".$opt{'long'} if exists($opt{'long'});
            $line .= ' ' x (29 - length($line));
            $line .= " <".$opt{'arg'}."> " if exists($opt{'arg'});
            $line .= ' ' x (39 - length($line))." ";
            $line .= $opt{'text'};
            $line .= ' (default '.$opt{'default'}.')' if exists($opt{'default'});
            print $line."\n";
            if (exists($opt{'negate'})) {
                print "    --no".$opt{'long'}."\n";
            }

        }
    }
}

1;

=head1 NAME
    surgat - Surgat configuration module

=head1 DESCRIPTION
    B<This program> will read the arguments supplied and attempt to do something
    sensible with them. It also contains enough information to provide a fully
    explained usage guide.

=cut
