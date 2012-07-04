#!/usr/bin/env perl
use strict;
use Encode;
use XMLRPC::Lite;
use DBI;
use WWW::Curl::Form;
use WWW::Curl::Easy;
use utf8;

#####################################################

# load configuration
my $config = confLoad("config.ini");

# load command-line arguments: language pair, job numeric ID, filename of the submitted file
my ($langPair, $jobId, $origFilename) = @ARGV;

# check if the language pair is set up in the configuration
checkLangPair($config, $langPair);

# initialize filenames for intermediate files
my $tmpFilenames = initTmpFilenames($config, $jobId);

# tokenize input using the configurated external script
doTokenization($config, $tmpFilenames, $langPair);

##### translate and re-case input #####

# prepare proxies for translation and re-casing
my $translProxy = getProxy($config, 'translation host list', $langPair);
my $recaseProxy = getProxy($config, 'recasing host list', $langPair);

# open input and output files
my $inFh = fopen($tmpFilenames->{'tok'});
my $outFh = fopen(">" . $tmpFilenames->{'rawtrans'});

while (my $text = <$inFh>) {
	# lower-case
	my $lcText = lowerCase($config, $text);

	# translate
	my $rawOut = communicate($config, $translProxy, $lcText);
	
	# re-case
	my $recasedOut = reCase($config, $rawOut, $recaseProxy);
	
	# output the result
	print $outFh $recasedOut . "\n";
}

close($outFh);
close($inFh);

# de-tokenize output using the configurated external script
doDeTokenization($config, $tmpFilenames, $langPair);

# report results by either performing a call-back (if the host is configured) or by updating the job the status
reportResults($config, $jobId, $tmpFilenames, $origFilename);

#####################################################

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
	my ($config, $proxy, $text) = @_;
	
	$text =~ s/[\r\n]//g;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
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
		
		$nextUp = ($inWord =~ /^[.?!]$/)
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
sub confBool {
	my ($str) = @_;
	
	return ($str eq "true");
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
	my ($dbh, $jobId) = @_;
	
	$dbh->do("update trids set is_done = 1 where id = $jobId");
}

#####
#
#####
sub cleanup {
	my ($dbh, $jobId, $jobPath) = @_;
	
	$dbh->do("delete from trids where id = $jobId");
	
	#system("rm -r $jobPath");
}

#####
#
#####
sub performCallBack {
	my ($jobId, $resultPath, $origFilename) = @_;
	
	my $curl = WWW::Curl::Easy->new;

	my $curlForm = WWW::Curl::Form->new;
	$curlForm->formaddfile($resultPath, "file", "multipart/form-data");
	$curlForm->formadd("requestID", "" . $jobId);
	$curlForm->formadd("fileName", $origFilename);

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

#####
#
#####
sub checkLangPair {
	my ($conf, $lp) = @_;
	
	my $translHostList = confHash($conf->{'translation host list'});
	my $recaseHostList = confHash($conf->{'recasing host list'});
	
	unless (defined($translHostList->{$lp}) and defined($recaseHostList->{$lp})) {
		die("Failed to locate port for language pair `$lp'");
	}
}

#####
#
#####
sub initTmpFilenames {
	my ($config, $jobId) = @_;
	
	my $jobPath = $config->{'work dir'} . "/" . $jobId;
	
	# input = raw input file
	# tok = tokenized input file
	# rawtrans = translated, re-cased file
	# detok = de-tokenized file
	
	# toklog = log file of the tokenizer
	# detoklog = log file of the de-tokenizer
	
	# timecodes = timecode file
	
	return {map { $_ => $jobPath . "/" . $_ . ".txt" } qw(input tok rawtrans detok toklog detoklog timecodes)};
}

#####
#
#####
sub doTokenization {
	my ($config, $tmpNames, $langPair) = @_;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
	# if in raw text mode, skip tokenization
	if ($rawTextMode) {
		$tmpNames->{'tok'} = $tmpNames->{'input'};
	}
	else {
		my ($srcLang) = split(/-/, $langPair);
		
		my $tokScript = $config->{'tokenizer'};
		
		system("$tokScript -l $srcLang" .
			" <" . $tmpNames->{'input'} .
			" >" . $tmpNames->{'tok'} .
			" 2>" . $tmpNames->{'toklog'});
		
		unless ($? == 0) {
			die("Failed to tokenize file ($!)");
		}
	}
	
	unless (-e $tmpNames->{'tok'}) {
		die("Tokenized input file was not generated");
	}
}

#####
#
#####
sub doDeTokenization {
	my ($config, $tmpNames, $langPair) = @_;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
	# if in raw text mode, skip de-tokenization
	if ($rawTextMode) {
		$tmpNames->{'detok'} = $tmpNames->{'rawtrans'};
	}
	else {
		my ($srcLang, $tgtLang) = split(/-/, $langPair);
		
		my $detokScript = $config->{'detokenizer'};
		
		system("$detokScript -l $tgtLang" .
			" <" . $tmpNames->{'rawtrans'} .
			" >" . $tmpNames->{'detok'} .
			" 2>" . $tmpNames->{'detoklog'} );
		
		unless ($? == 0) {
			die("Failed to de-tokenize file ($!)");
		}
	}
	
	unless (-e $tmpNames->{'detok'}) {
		die("De-tokenized output file was not generated");
	}
}

#####
#
#####
sub getProxy {
	my ($config, $listId, $lp) = @_;
	
	my $list = confHash($config->{$listId});
	
	return XMLRPC::Lite->proxy($list->{$lp});
}

#####
#
#####
sub lowerCase {
	my ($config, $text) = @_;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
	return ($rawTextMode? $text: lc($text));
}

#####
#
#####
sub reCase {
	my ($config, $rawTranslation, $proxy) = @_;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
	return ($rawTextMode? $rawTranslation: finalizeRecasing(communicate($config, $proxy, $rawTranslation)));
}

#####
#
#####
sub reportResults {
	my ($config, $jobId, $tmpNames, $origFilename) = @_;
	
	my $jobPath = $config->{'work dir'} . "/" . $jobId;
	
	# initialize a DB connection
	my $dbPath = $config->{'db path'};
	my $dbh = DBI->connect("dbi:SQLite:dbname=$dbPath","","");
	
	# if the call-back URL is defined, perform call-back
	if (defined($config->{'call-back url'})) {
		performCallBack($jobId, $tmpNames->{'detok'}, $origFilename);
		
		#delete the directory and update the status
		cleanup($dbh, $jobId, $jobPath);
	}
	
	# otherwise, save status for retrieval via getresults.php
	else {
		saveStatus($dbh, $jobId);
	}
}
