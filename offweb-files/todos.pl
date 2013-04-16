#!/usr/bin/perl
use strict;

binmode(STDIN, ':utf8');
binmode(STDOUT, ':utf8');

while (<STDIN>) {
	s/\n$/\r\n/g;
	print;
}
