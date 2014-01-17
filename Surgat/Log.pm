package Surgat::Log;

use strict;

use Exporter ();
use Sys::Syslog qw(syslog);

{
    no strict 'vars';
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(do_log set_log_function);
}

my $log_level = 2;
my $syslog = 0;
my $logformat = "%Y-%b-%d %H:%M:%S";

our %syslog_map = (0 => 'err', 1 => 'warning', 2 => 'notice', 3 => 'info', 4 => 'debug');

sub initial_logger {
    my ($lvl, $msg);
    print STDOUT $msg."\n";
}
my $log_function = \&initial_logger; 

sub get_datetime {
    return POSIX::strftime($logformat, gmtime);
}

sub do_log {
    my ($level, @msg) = @_;

    my $levelstr = $syslog_map{$level} if $level =~ /^\d/ || $level;
    my $caller = caller();
    foreach my $m (@msg) {
        $log_function->($level, format_msg($caller, $levelstr, $m));
    }
};

sub format_msg {
    my ($caller, $level, $msg) = @_;
    $msg =~ s/\%/%%/g;
    my $rv = sprintf("%s: %s: %s", $caller, $level, $msg);
#    $rv = sprintf("%s %s", get_datetime, $rv) unless $syslog;
    return $rv;
}

sub set_log_function { $log_function = shift; }

1;

=head1 NAME

Surgat::Log Very simple logging function.

=head2 Methods

=over 12

=item C<do_log>

Log a message at a given level to the currently defined syslog.

=back

=cut
