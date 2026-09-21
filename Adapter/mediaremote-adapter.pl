#!/usr/bin/perl
#
# Runs the MediaRemote adapter inside Perl.
#
# The point of this script is *which process* the code runs in. MediaRemote's
# now-playing metadata is gated to Apple-signed callers, so the same calls that
# return nil inside Fringe succeed here.
#
# DynaLoader installs an exported C symbol as an XSUB and calls it with no
# arguments; parameters go through the environment so the adapter never has to
# touch the Perl API.
#
#   mediaremote-adapter.pl <framework-dir> stream
#   mediaremote-adapter.pl <framework-dir> get
#   mediaremote-adapter.pl <framework-dir> test
#   mediaremote-adapter.pl <framework-dir> send <command-id>

use strict;
use warnings;
use DynaLoader;
use File::Basename;
use File::Spec;

sub fail {
    print STDERR "$_[0]\n";
    exit 1;
}

my $framework_path = shift @ARGV or fail "Usage: $0 <framework-dir> <function> [args]";
my $function = shift @ARGV or fail "Missing function";

my %allowed = map { $_ => 1 } qw(test get stream send);
fail "Unknown function: $function" unless $allowed{$function};

my $name = File::Basename::basename($framework_path);
$name =~ s/\.framework$// or fail "Not a framework: $framework_path";

my $binary = File::Spec->catfile($framework_path, $name);
fail "Adapter binary missing: $binary" unless -e $binary;

if ($function eq 'send') {
    my $command = shift @ARGV;
    fail "send requires a command id" unless defined $command;
    fail "Command id must be a number" unless $command =~ /^\d+$/;
    $ENV{'MEDIAREMOTEADAPTER_COMMAND'} = $command;
}

my $handle = DynaLoader::dl_load_file($binary, 0)
    or fail "Failed to load adapter: $binary";

my $symbol = DynaLoader::dl_find_symbol($handle, "adapter_$function")
    or fail "Adapter is missing symbol adapter_$function";

DynaLoader::dl_install_xsub("main::adapter_entry", $symbol);
adapter_entry();
