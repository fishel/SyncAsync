#!/usr/bin/perl
use strict;

our $nl = "\r\n";

while (<STDIN>) {
	if (/^\s*(\d+)\s+(\d\d:\d\d:\d\d):(\d\d)\s+(\d\d:\d\d:\d\d):(\d\d)\s*$/) {
		my ($idx, $t1, $f1, $t2, $f2) = ($1, $2, $3, $4, $5);
		
		my ($s1, $s2) = ($f1 * 40, $f2 * 40);
		
		$idx =~ s/^0*//g;
		
		print "$idx$nl$t1,$s1 --> $t2,$s2$nl";
	}
	else {
		print;
	}
}
