package Surgat::Proxy;

use strict;

use IO::File;
use IO::Socket;

use Surgat::Log qw(do_log);

use constant IN  => 1;
use constant OUT => 2;

sub new {
    my($this, $socket, $config, $spamtest) = @_;
    my $class = ref($this) || $this;
  
    die "$0: socket bind failure: $!\n" unless defined $socket;

    my $self = {insock => $socket, 
                spamtest => $spamtest, 
                state => 'created',
                recipients => ()};
    bless($self, $class);

    # todo - allow for lmtp connections here...
    $self->{outsock} = IO::Socket::INET->new(
			PeerAddr => $config->{'relay-host'},
			PeerPort => $config->{'relay-port'},
			Timeout => $config->{'timeout'},
			Proto => 'tcp',
			Type => SOCK_STREAM,
	);
    die "$0: unable to connect to remote server: $!\n" unless defined $self->{outsock};

    return $self;
}

sub start {
    my $self = shift;
    my ($greeting, $code) = $self->_recv_multi(OUT) or return 0;
    return 0 unless $code == 220;
    $self->_send(IN, "$greeting\r\n") or return 0;
    $self->change_state("connected");
    return 1;
}

sub process_commands {
    my $self = shift;

    while (1) {
        # get a command...
        # read a command from the input socket...
        my $cmd = $self->_recv(IN);
        return 0 unless defined $cmd;
        $cmd =~ s/[\r\n]*$//;

        # Sending a second size statement is not permitted - should
        # we check?
        $self->{size} = $1 if $cmd=~/SIZE=([0-9]+)/;
#:<david@X201> ORCPT=rfc822;david
        push(@{$self->{recipients}}, $1) if $cmd =~ /rcpt to:\<(.*)\>/i;
        do_log(4, $cmd) if $cmd =~ /rcpt to/i;

        if ($cmd =~ /QUIT/i) {
            # Presently, there is a chance that the connection will have
            # already been closed here if we've taken longer than the
            # client wanted to wait while we processed the message.
            # It's not an error and we should simply carry on.
            $self->_send(IN, "221 2.0.0 Bye\r\n");
            $self->{insock}->close;
            $self->change_state("inbound socket closed");
            return 1;
        }
        # write the command to output socket...
        $self->_send(OUT, "$cmd\r\n");
        # read reply from output socket...
        my ($reply, $code) = $self->_recv_multi(OUT);
        # send the reply to input socket...
        $self->_send(IN, "$reply\r\n");

        # should we continue?
        last if $code == 354;
        next unless $code == 250;
    }
    do_log(4, $self->{recipients}."\n");
    return 1;
}

sub read_data {
    my $self = shift;
    if (defined($self->{data})) {
        # pipelining?
        # todo - there is a chance we could loose data here,
        # so what should we do?
        $self->{data}->seek(0, 0);
	    $self->{data}->truncate(0);
    } else {
        $self->{data} = IO::File->new_tmpfile;
    }
    $self->change_state('Reading data');
    while (defined(my $line = $self->_recv(IN))) {
        last if $line =~ /^\.\r\n/;
        if (!$self->{data}->print($line)) {
            do_log(0, "Error printing data to temporary file");
            return 0;
        }
    }
    $self->change_state('Data received');
    return 1;
}

sub accept_message {
    my $self = shift;
    $self->change_state('Message accepted');
    $self->_send(IN, "250 2.0.0 Ok: message has been processed");
}

sub temporary_defer {
    my $self = shift;
    # Called when there was an error processing message through spamassassin.
    $self->change_state('Data temporarily rejected');
    $self->_send(IN, "451 4.7.1 Unable to process message at this time. Please try later");
}

sub change_state {
    my ($self, $state) = @_;
    $self->{state} = $state;
    do_log(3, "state changed: ".$self->{state});
}

sub send_data {
    my ($self, $data) = @_;
    return 0 unless $self->{outsock};
    local ($/) = "\r\n";
    $self->{outsock}->autoflush(0);
    while (<$data>) {
        s/^\./../;
        $self->{outsock}->print($_) or return 0;
    }
    $self->{outsock}->autoflush(1);
    $self->{outsock}->print(".\r\n") or return 0;
    return 1;
}

sub process_message {
    my $self = shift;
    my $rv;

    $self->change_state("processing message");
    return 0 unless defined $self->{data};

    # Process the message via spamtest. We hope to be called on a
    # 1-1 basis, but if default_destination_recipient_limit  is not set
    # to 1 then we'll possibly end up with multiple recipients. At this
    # stage we have already passed on the recipients to the outgoing end
    # of the proxy, so we'll just process using the spam settings for
    # the first recipient.
    # NB This assumes we have recipients!
    my $rcpt = pop(@{$self->{recipients}});
    my $result = $self->{spamtest}->process($self->{data}, $rcpt);
    $self->change_state("message processing result: $result");

    # 3 results possible...
    # RESULT_HAM        0
    # RESULT_SPAM       1
    # RESULT_TOO_LARGE  2
    if ($result == Surgat::Spamtest::RESULT_TOO_LARGE) {
        # We haven't processed the message, so just send message contents.
        # Start by rewinding the temporary file, then send it all.
        $self->{data}->seek(0,0) or die "Can't rewind mail file: $!";
        $rv = $self->send_data($self->{data});
    } else {
        # Message has been processed, so we're going to send the modified one.
        $self->{spamtest}->{response}->seek(0,0) or die "Unable to rewind modified content: $!";
        $rv = $self->send_data($self->{spamtest}->{response});
    }
    $self->change_state("message processing completed");
    return $rv;
}

sub finish {
    my $self = shift;
    # todo - If insock is still open, we should close it here.
    $self->{outsock}->close;
    $self->{data}->close if defined $self->{data};
    $self->{spamtest}->finish();
}

sub _recv {
    my ($self, $which) = @_;
    local ($/) = "\r\n";
#    my $direction = "R ".($which == IN ? " << " : " >> ");
    return undef unless my $tmp = ($which == IN ? $self->{insock} : $self->{outsock})->getline;
#    do_log(4, $direction.$tmp);
    return $tmp;
}

sub _recv_multi {
    my ($self, $which) = @_;
    my $line = $self->_recv($which);
    my ($data, $code);
    return undef if ! defined $line;
    while ($line =~ /^(\d{3})-/) {
        $data .= $line;
        $code = int($1);
        $line = $self->_recv($which);
    }
    $code = int($1) if $line =~ /^(\d{3})/;
    $data .= $line;
    $data =~ s/\r\n$//;    
    return ($data, $code);
}

sub _send {
    my ($self, $which, @msg) = @_;
    return unless @msg;
    my $sock = $which == IN ? $self->{insock} : $self->{outsock};

    # Log all sending...
#    my $direction = "S ".($which == IN ? " << " : " >> ");
#    foreach my $part (@msg) {
#        my @pieces = split("\r\n", $part);
#        foreach my $p (@pieces) { do_log(4, $direction.$p); }
#    }

    if (! $sock->print(@msg)) {
        do_log(1, "$0: Unable to send @msg to $which: $!"); 
        return;
    }
    $sock->print("\r\n") unless @msg[-1] =~ /\r\n$/;
}

1;

=head1 NAME

Surgat::Proxy   A class to create and manage a transparent proxy connection.

=head1 SYNOPSIS

    my $p = Surgat::Proxy->new($client, $config, $spamtest);
    unless ($p->start()) { die "$0: Unable to establish proxy connection: $!"; }
    unless ($p->process_commands()) { die "$0: Error processing commands: $!"; }
    unless ($p->read_data()) { die "$0: Error reading mail from connection: $!") };
    unless ($p->process_message()) { die "$0: Error processing the mail message: $!") };
    unless ($p->process_commands()) { die "$0: Error processing commands: $!"; }
    $p->finish();

=head1 SEE ALSO

L<Surgat::Server>, L<Surgat::Spamtest>

=cut
