#!/usr/bin/env perl
use strict;
use Encode;
use XMLRPC::Lite;
use DBI;
use utf8;
use config;

##### Configuration #####
our $config = config::load();

our $translHostList = config::hash($config->{'translation host list'});
our $recaseHostList = config::hash($config->{'recasing host list'});

our $rawTextMode = ($config->{'raw text'} eq "true");

our $jobPathBase = $config->{'work dir'};

##### Translation #####

my ($langpair, $jobId) = @ARGV;

my ($srcLang, $tgtLang) = split(/-/, $langpair);

unless (defined($translHostList->{$langpair}) and defined($recaseHostList->{$langpair})) {
	die("Failed to locate port for language pair `$langpair'");
}

### file name var init
my $jobPath = $jobPathBase . "/" . $jobId;

my ($inName, $tokName, $rawOutName, $outName, $tokLogName, $detokLogName) = map { $jobPath . "/" . $_ }
	qw(input.txt tok-input.txt raw-output.txt output.txt tok.log detok.log);

### tokenize and lower-case input

if ($rawTextMode) {
	#skip tokenization
	$tokName = $inName;
}
else {
	my $tokScript = $config->{'tokenizer'};

	system("$tokScript -l $srcLang <$inName >$tokName 2>$tokLogName");

	unless ($? == 0 and -e $tokName) {
		die("Failed to tokenize file ($!)");
	}
}

### translate and re-case input

my $translProxy = XMLRPC::Lite->proxy($translHostList->{$langpair});
my $recaseProxy = XMLRPC::Lite->proxy($recaseHostList->{$langpair});

my $inFh = fopen($tokName);
my $outFh = fopen(">$rawOutName");

while (my $text = <$inFh>) {
	# lower-case
	my $lcText = ($rawTextMode? $text: lc($text));

	# translate
	my $rawOut = communicate($translProxy, $lcText);
	
	# re-case
	my $recasedOut = ($rawTextMode? $rawOut: finalizeRecasing(communicate($recaseProxy, $rawOut)));
	
	# output the result
	print $outFh $recasedOut . "\n";
}

close($outFh);
close($inFh);

### de-tokenize

my $detokScript = $config->{'detokenizer'};

system("$detokScript -l $tgtLang <$rawOutName >$outName 2>$detokLogName");

unless ($? == 0 and -e $tokName) {
	die("Failed to de-tokenize file ($!)");
}

### report result

our $dbPath = $config->{'db path'};

my $dbh = DBI->connect("dbi:SQLite:dbname=$dbPath","","");
$dbh->do("update trids set is_done = 1 where id = $jobId");

#####
#
#####
sub fopen {
	my ($fname) = @_;
	
	open(my $fh, $fname) or die("Failed to open `$fname'");
	binmode($fh, ':utf8');
	
	return $fh;
}

#####
#
#####
sub communicate {
	my ($proxy, $text) = @_;
	
	$text =~ s/[\r\n]//g;
	
	if ($rawTextMode) {
		#TODO ALS, please insert your communication code here
		die("TODO");
	}
	else {
		my $encoded = SOAP::Data->type(string => Encode::encode("utf8", $text));
		
		my $rawResult = $proxy->call("translate", { 'text' => $encoded });
		
		return $rawResult->result->{'text'};
	}
}

#####
#
#####
sub finalizeRecasing {
	my ($rawRecOut) = @_;
	
	my @inWords = split(/ /, $rawRecOut);
	my @outWords = ();
	my $nextUp = 1;
	
	for my $inWord (@inWords) {
		push @outWords, ($nextUp? ucfirst($inWord): $inWord);
		
		$nextUp = ($inWord =~ /^[[:punct:]]$/)
	}
	
	return join(" ", @outWords);
}
