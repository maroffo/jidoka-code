#!/usr/bin/perl
use strict;
use warnings;

use POSIX qw(
    SIG_BLOCK SIG_SETMASK SIGHUP SIGINT SIGTERM WNOHANG setpgid sigprocmask
);
use Time::HiRes qw(CLOCK_MONOTONIC clock_gettime sleep);

sub monotonic_time {
    return clock_gettime(CLOCK_MONOTONIC);
}

sub process_group_exists {
    my ($pid) = @_;
    return kill(0, -$pid) > 0;
}

# Cleanup authority is the dedicated process group. Callers must use commands
# whose descendants do not daemonize, reparent, or escape it with setsid().
sub terminate_group {
    my ($pid, $signal) = @_;
    my $status;

    kill $signal, -$pid;
    my $grace_deadline = monotonic_time() + 2.0;
    while (monotonic_time() < $grace_deadline) {
        if (!defined $status) {
            my $waited = waitpid($pid, WNOHANG);
            $status = $? if $waited == $pid;
            return (undef, 0) if $waited == -1;
        }
        last if defined $status && !process_group_exists($pid);
        sleep(0.05);
    }

    kill 'KILL', -$pid if process_group_exists($pid);
    if (!defined $status) {
        while (1) {
            my $waited = waitpid($pid, 0);
            if ($waited == $pid) {
                $status = $?;
                last;
            }
            return (undef, 0) if $waited == -1;
        }
    }

    my $kill_deadline = monotonic_time() + 2.0;
    while (process_group_exists($pid) && monotonic_time() < $kill_deadline) {
        sleep(0.05);
    }
    return ($status, !process_group_exists($pid));
}

@ARGV >= 2 or die "usage: run-bounded-command.pl <seconds> <absolute-executable> [args...]\n";
my $timeout = shift @ARGV;
$timeout =~ /\A[1-9][0-9]*\z/ && $timeout <= 3600
    or die "invalid bounded-command timeout\n";
my @command = @ARGV;
$command[0] =~ m{\A/} && -f $command[0] && -x $command[0] && !-l $command[0]
    or die "bounded command executable must be an absolute regular file\n";

my $blocked_signals = POSIX::SigSet->new(SIGHUP, SIGINT, SIGTERM);
my $previous_signals = POSIX::SigSet->new();
defined sigprocmask(SIG_BLOCK, $blocked_signals, $previous_signals)
    or die "bounded command signal setup failed\n";

my $pid = fork();
if (!defined $pid) {
    sigprocmask(SIG_SETMASK, $previous_signals);
    die "bounded command fork failed\n";
}
if ($pid == 0) {
    defined setpgid(0, 0) or die "bounded command process-group setup failed\n";
    defined sigprocmask(SIG_SETMASK, $previous_signals)
        or die "bounded command signal restore failed\n";
    exec { $command[0] } @command;
    die "bounded command exec failed\n";
}

# The child also establishes its group before exec. The parent call closes the
# interval before signal handlers are installed; a child that already exited is
# handled by waitpid below.
setpgid($pid, $pid);
my $forwarded_signal = 0;
$SIG{HUP} = sub { $forwarded_signal = 1; };
$SIG{INT} = sub { $forwarded_signal = 2; };
$SIG{TERM} = sub { $forwarded_signal = 15; };
defined sigprocmask(SIG_SETMASK, $previous_signals)
    or die "bounded command signal restore failed\n";

my $deadline = monotonic_time() + $timeout;
my $status;
while (1) {
    if ($forwarded_signal != 0) {
        my ($ignored_status, $cleared) = terminate_group($pid, $forwarded_signal);
        if (!$cleared) {
            print STDERR "bounded command process-group cleanup failed\n";
            exit 125;
        }
        exit 128 + $forwarded_signal;
    }

    my $waited = waitpid($pid, WNOHANG);
    if ($waited == $pid) {
        $status = $?;
        last;
    }
    if ($waited == -1) {
        die "bounded command wait failed\n";
    }
    if (monotonic_time() >= $deadline) {
        my ($ignored_status, $cleared) = terminate_group($pid, 'TERM');
        if (!$cleared) {
            print STDERR "bounded command process-group cleanup failed\n";
            exit 125;
        }
        print STDERR "bounded command timed out after ${timeout}s\n";
        exit 124;
    }
    sleep(0.05);
}

if (($status & 127) == 0) {
    exit($status >> 8);
}
exit(128 + ($status & 127));
