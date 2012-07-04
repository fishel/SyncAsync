#!/usr/bin/env perl
use strict;
use Encode;
use XMLRPC::Lite;
use DBI;
use WWW::Curl::Form;
use WWW::Curl::Easy;
use utf8;

##### Configuration #####
our $config = confLoad("config.ini");

our $translHostList = confHash($config->{'translation host list'});
our $recaseHostList = confHash($config->{'recasing host list'});

our $rawTextMode = ($config->{'raw text'} eq "true");

our $jobPathBase = $config->{'work dir'};

##### Translation #####

my ($langpair, $jobId, $filename) = @ARGV;

my ($srcLang, $tgtLang) = split(/-/, $langpair);

unless (defined($translHostList->{$langpair}) and defined($recaseHostList->{$langpair})) {
	die("Failed to locate port for language pair `$langpair'");
}

### file name var init
our $jobPath = $jobPathBase . "/" . $jobId;

my ($inName, $tokName, $rawOutName, $outName, $tokLogName, $detokLogName, $timecodeName) = map { $jobPath . "/" . $_ }
	qw(input.txt tok-input.txt raw-output.txt output.txt tok.log detok.log timecodes.dat);

### tokenize and lower-case input

# if in raw text mode, skip steps and send text instead of an XMLRPC request
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

my $dbPath = $config->{'db path'};

our $dbh = DBI->connect("dbi:SQLite:dbname=$dbPath","","");

# if the call-back URL is defined, perform call-back
if (defined($config->{'call-back url'})) {
	performCallBack($jobId, $outName, $filename);
	
	#delete the directory and update the status
	cleanup($jobId, $jobPath);
}
# otherwise, save status for retrieval via getresults.php
else {
	saveStatus($jobId);
}

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

#####
#
#####
sub confLoad {
	my ($configFilePath) = @_;
	
	my $result = {};
	
	open(FH, $configFilePath) or die ("Failed to open `$configFilePath' for reading");
	
	while (<FH>) {
		s/[\n\r]//g;
		
		if (/^\s*$/ or /^\s*#/) {
			#empty or comment line, do nothing
		}
		elsif (/^([^=]+)=(.*)$/) {
			my $key = normalize($1);
			my $val = normalize($2);
			
			#print STDERR "found $key -> $val!\n";
			
			unless ($val) {
				$val = readMultilineValue(*FH);
				#print STDERR "val re-read: `$val'\n";
			}
			
			$result->{$key} = $val;
		}
		else {
			die ("Choked on config line `$_'")
		}
	}
	
	close(FH);
	
	return $result;
}

#####
#
#####
sub readMultilineValue {
	my ($fh) = @_;
	
	my $val = "";
	
	my $buf = <$fh>;
	
	while ($buf and !($buf =~ /^\s*$/) and !($buf =~ /^\s*#/)) {
		$buf =~ s/[\n\r]//g;
		
		$val .= $buf . "\n";
		
		$buf = <$fh>;
	}
	
	return $val;
}

#####
#
#####
sub normalize {
	my ($str) = @_;
	
	$str =~ s/\s+/ /g;
	$str =~ s/^ //g;
	$str =~ s/ $//g;
	
	return $str;
}

#####
#
#####
sub confHash {
	my ($str) = @_;
	
	my %result =
		map { my ($k, $v) = split(/\s+/); $k => $v }
		grep {!/^\s*$/}
		split(/\n/, $str);
	
	return \%result;
}

#####
#
#####
sub logHash {
	my ($href) = @_;

	print STDERR join("\n", map { join("=>", $_, $href->{$_}) } keys %$href) . "\n";
}

#####
#
#####
sub saveStatus {
	my ($jobId) = @_;
	
	$dbh->do("update trids set is_done = 1 where id = $jobId");
}

#####
#
#####
sub cleanup {
	my ($jobId) = @_;
	
	$dbh->do("delete from trids where id = $jobId");
	
	#system("rm -r $jobPath");
}

#####
#
#####
sub performCallBack {
	my ($jobId, $resultPath, $filename) = @_;
	
	my $curl = WWW::Curl::Easy->new;

	my $curlForm = WWW::Curl::Form->new;
	$curlForm->formaddfile($resultPath, "file", "multipart/form-data");
	$curlForm->formadd("requestID", "" . $jobId);
	$curlForm->formadd("fileName", $filename);

	$curl->setopt(CURLOPT_HTTPPOST, $curlForm);

	$curl->setopt(CURLOPT_HEADER, 1);
	$curl->setopt(CURLOPT_URL, $config->{'call-back url'});

	my $response_body;
	$curl->setopt(CURLOPT_WRITEDATA, \$response_body);

	# Starts the actual request
	my $retcode = $curl->perform;
	
	unless ($retcode == 0) {
		die("An error happened at call-back: $retcode " .
			$curl->strerror($retcode) . "; " . $curl->errbuf . "\n");
	}
}
