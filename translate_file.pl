#!/usr/bin/env perl
use strict;
use Encode;
use XMLRPC::Lite;
use DBI;
use utf8;

##### Configuration #####
my $dbPath = "/home/mfishel/offweb/db/trids.sqlite";
my $host = "http://localhost";
my %ports = (
	'de-en' => 1984
	);

##### Translation #####

my ($langpair, $jobPath, $jobId) = @ARGV;
my $port = $ports{$langpair};

unless ($port) {
	die("Failed to locate port for language pair `$langpair'");
}

my ($inName, $outName) = ("$jobPath/input.txt", "$jobPath/output.txt");

my $url = "$host:$port/RPC2";
my $proxy = XMLRPC::Lite->proxy($url);

open(INFH, $inName) or die("Failed to open `$inName' for reading");
binmode(INFH, ':utf8');
open(OUTFH, ">$outName") or die("Failed to open `$outName' for writing");
binmode(OUTFH, ':utf8');

while (my $text = <INFH>) {
	$text =~ s/[\r\n]//g;

	my $encoded = SOAP::Data->type(string => Encode::encode("utf8", $text));

	my %param = ("text" => $encoded);
	
	print "translating\n";
	
	my $result = $proxy->call("translate",\%param)->result;
	
	print OUTFH $result->{'text'} . "\n";
	
}

close(OUTFH);
close(INFH);

my $dbh = DBI->connect("dbi:SQLite:dbname=$dbPath","","");
$dbh->do("update trids set is_done = 1 where id = $jobId");

