#!/usr/bin/perl
use strict;

binmode(STDIN, ':utf8');
binmode(STDOUT, ':utf8');

while (<STDIN>) {
	s/\r//g;
	print;
}
