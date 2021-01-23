#!/usr/bin/perl

my $old_problem_file = "/var/run/drbd.problem";

use strict;
use warnings;
use Mail::Sendmail;
use File::Slurp;
use Sys::Hostname;

my $noisy = 0;

if (@ARGV && $ARGV[0] eq 'noisy') {
	$noisy = 1;
}

my %found;
my @problem;
my $copy;
my $hostname = hostname();


my %totallygood;
my %connected;

open my $drbd, "<", "/proc/drbd" or die;
while (<$drbd>) {
	$copy .= $_;
	next unless /^\s*(\d+):\s/;
	my $r = $1;
	$found{$r}++;
	if (m{cs:(Connected|SyncTarget|SyncSource)}) {
		$connected{$r} = 1;
	} else {
		if (m{ro:Primary}) {
			push(@problem, "r$r is unconnected primary")
		} else {
			push(@problem, "r$r not connected");
		}
	}
	if (m{ds:UpToDate/UpToDate}) {
		$totallygood{$r} = 1;
		next;
	}
	push(@problem, "r$r not up-to-date");
}

push(@problem, "no drbd issues, all is good") unless @problem;

my $old_problem = -e $old_problem_file ? read_file($old_problem_file) : '';
my $new_problem = join("\n", @problem);

if ($new_problem ne $old_problem || $noisy) {
	my $body = join("\n", @problem, "", "", $copy);
	sendmail(
		Smtp	=> '127.0.0.1',
		From	=> "Root Guy <root\@$hostname>",
		To	=> "root\@$hostname",
		Subject	=> "$hostname: drbd status",
		Message	=> $body,
	) or die "could not send: $Mail::Sendmail::error";

	write_file($old_problem_file, $new_problem);
	
	print "SENDING MESSAGE\n$body" if -t STDOUT;
} else {
	print "Not sending: @problem\n" if -t STDOUT;
}

