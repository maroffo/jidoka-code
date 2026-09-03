#!/usr/bin/perl
use strict;
use warnings;

my $runner = delete $ENV{JIDOKA_NATIVE_BOUNDED_COMMAND_RUNNER};
defined $runner && $runner =~ m{\A/} && -f $runner && -x $runner && !-l $runner
    or die "native bounded command runner is unavailable\n";
exec { $runner } $runner, @ARGV;
die "native bounded command runner exec failed\n";
