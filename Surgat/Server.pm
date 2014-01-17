package Surgat::Server;

use strict;
use IO::File;
use Net::Server::PreForkSimple;

use base qw(Net::Server::PreForkSimple);

use Surgat::Spamtest;
use Surgat::Proxy;
use Surgat::Log qw (do_log set_log_function);

sub new {
    my($this, $config) = @_;
    my $class = ref($this) || $this;
    my $self = {};

    my $srv = $self->{'server'} ||= {};

    # Only support IPv4 at present...
    $self->{config} = $config;
    $srv->{ipv} = $config->{'ipv4-only'} ? 4 : '*';
    $self->{timeout} = $config->{'timeout'};
    $self->{logformat} = $config->{'logformat'};

    my %server_options_to_set = (
        'port' => 'listen-port',
        'host' => 'listen-host',
        'user' => 'username',
        'group' => 'groupname',
        'max_servers' => 'children',
        'max_requests' => 'max-conn-per-child',
        'background' => 'daemonize',
        'pid_file' => 'pidfile',
    );

    foreach my $opt (sort keys %server_options_to_set) {
        $srv->{$opt} = $config->{$server_options_to_set{$opt}};
    }

    $srv->{'log_level'} = $config->{'log-level'};
    if ($config->{'syslog'}) {
        $srv->{'log_file'} = 'Sys::Syslog';
        $srv->{'syslog_ident'} = $config->{'syslog-ident'};
        $srv->{'syslog_logsock'} = $config->{'syslog-socket'};
        $srv->{'syslog_facility'} = $config->{'syslog-facility'};
    } else {
        $srv->{'log_file'} = $config->{'logfile'};
    }
    
    if ($self->{log_level} == 0) {
        $SIG{__WARN__} = sub { $self->log(1, $_[0]); };
    }

    $self->{state} = 'started';
    $self->{children} = 0;

    # bless ourselves, then return
    bless($self, $class);
    return $self;
}

sub post_configure_hook {
    # Set the logging function.
    my $self = shift;
    my $srv = $self->{'server'};
    my $log_fn = sub { $self->dolog(@_); };
    set_log_function($log_fn);
    do_log(2, "surgut transparent proxy for spamassassin started.");
}

sub child_init_hook {
    my $self = shift;
    $self->{spamtest} = Surgat::Spamtest->new($self->{config});
}

sub log_time {
    my $self = shift;
    return POSIX::strftime($self->{'logformat'}, gmtime);
}

sub process_request {
    my $self = shift;
    eval {
    	local $SIG{ALRM} = sub { die "Child server process timed out!\n" };
#	    my $timeout = $self->{timeout};
	    alarm($self->{timeout});

        my $p = Surgat::Proxy->new($self->{server}->{client}, $self->{config}, $self->{spamtest});
        unless ($p->start()) { die "$0: Unable to establish proxy connection: $!"; }

        # Process commands until we see DATA...        
        if (! $p->process_commands()) {
            die("Error processing commands: $!");
        }
        # Read data and store it. Respond and close inbound socket...
        if (! $p->read_data()) {
            $p->finish();
            die("Error reading mail from connection: $!");
        }
        
        if (! $p->process_message()) {
            $p->temporary_defer();
            $p->finish();
            die("Error processing the mail message: $!");
        }

        $p->process_commands();
        $p->finish();
#        alarm($timeout);
    };
    alarm(0);
    # The eval block will "hide" any errors, so check if all went OK and record
    # any problems to stop hair pulling when there are bugs...
    if ($@ ne '') {
        chomp($@);
	    do_log(1, "Error processing a request: $@");
        die ("Request pocessing failed: $@\n");
    }

    return;
}

sub dolog {
    my ($self, $level, $msg) = @_;
    $self->log($level, $msg);
}

1;

=head1 NAME

Surgat::Server A preforked server to manage connections.

=head1 SYNOPSIS

  my $server = Surgat::Server->new($cfg);
  $server->run();

=head1 DESCRIPTION

Each instance of the server creates a number of children, each of which acts as a transparent proxy for mail.

=head2 Methods

=over 12

=item C<new>

Returns a new instance of the server.

=item C<run>

Starts the server accepting connection.

=back

=head1 SEE ALSO

L<Surgat::Configuration>, L<Surgat::Proxy>, L<Surgat::Spamtest>

=cut

