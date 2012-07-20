#!/usr/bin/env perl
use strict;
use Encode;
use DBI;
use WWW::Curl::Form;
use WWW::Curl::Easy;
use utf8;
use FindBin qw($Bin);
use Time::HiRes qw(gettimeofday);
use RPC::XML;
use RPC::XML::Client;

binmode(STDOUT, ':utf8');

our $LINE_BREAK = " _br_ ";

print "starting translation\n";

# load command-line arguments: language pair, job numeric ID, filename of the submitted file
my ($langPair, $jobId, $origFilename) = @ARGV;

# load configuration
my $config = confLoad($Bin . "/config.ini");

# exception handling: in case of exceptions update status to error and/or perform an error call-back
eval {
	# main file processing (tokenization, translation, reporting, etc.) is done here
	processFile($langPair, $jobId, $origFilename, $config);
};

# if an error has occured, report it
if ($@) {
	complain($config, $jobId, $origFilename, $@);
}

#####################################################
sub processFile {
	my ($langPair, $jobId, $origFilename, $config) = @_;

	# check if the language pair is set up in the configuration
	checkLangPair($config, $langPair);

	# initialize filenames for intermediate files
	my $tmpFilenames = initTmpFilenames($config, $jobId);

	# tokenize input using the configurated external script
	doTokenization($config, $tmpFilenames, $langPair);

	##### translate and re-case input #####

	# prepare proxies for translation and re-casing
	my $translProxy = getProxy($config, 'translation host list', $langPair);
	
	my ($srcLang, $tgtLang) = split(/-/, $langPair);
	my $recaseProxy = getProxy($config, 'recasing host list', $tgtLang);

	# open input and output files
	my $inFh = fopen($tmpFilenames->{'tok'});
	my $outFh = fopen(">" . $tmpFilenames->{'rawtrans'});
	
	my @subs = readSubtitles($inFh);
	
	my $t0 = gettime();
	
	for my $cell (@subs) {
		# perform lower-casing, translation and re-casing
		my $outText = translate($config, $cell, $translProxy, $recaseProxy);
		
		displayResults($outFh, $cell, $outText);
	}

	my $t1 = gettime();
	
	print "DEBUG total translation time: " . ($t1 - $t0) . "; #subs: " . (scalar @subs) . "\n";

	close($outFh);
	close($inFh);

	# de-tokenize output using the configurated external script
	doDeTokenization($config, $tmpFilenames, $langPair);

	# report results by either performing a call-back (if the host is configured) or by updating the job the status
	reportResults($config, $jobId, $tmpFilenames, $origFilename);
}

#####
#
#####
sub gettime {
	my ($sec, $msec) = gettimeofday();
	
	return $sec + $msec/1000000.0;
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
sub displayResults {
	my ($outFh, $cell, $translation) = @_;
	
	my $timeCodedOutput = (defined($cell->{'timecode'}));
	
	print $outFh 
		($timeCodedOutput? $cell->{'timecode'} . "\n": "") .
		$translation . "\n" .
		($timeCodedOutput? "\n": "");
}

#####
#
#####
sub communicate {
	my ($config, $proxy, $inputText) = @_;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
	if ($rawTextMode) {
		die("raw text mode communication not implemented yet");
	}
	else {
		$RPC::XML::ENCODING = "UTF-8";
		
		my $encodedInputBytes = Encode::encode("utf8", $inputText);
		
		my $encodedInput = RPC::XML::string->new($encodedInputBytes);
		
		my $request = RPC::XML::request->new(
			'translate',
			RPC::XML::struct->new({ 'text' => $encodedInput }));
		
		my $response = $proxy->send_request($request);
		
		if (!$response) {
			die $RPC::XML::ERROR;
		}
		elsif (!defined($response->{text})) {
			my $auxmsg = ${$response->{'faultString'}};;
			die "Proxy returned empty result: $auxmsg";
		}
		elsif (!defined($response->{text}->value)) {
			die "Proxy returned empty text";
		}
		else {
			return $response->{text}->value;
		}
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
	
	my $fh = fopen($configFilePath);
	
	while (<$fh>) {
		s/[\n\r]//g;
		
		if (/^\s*$/ or /^\s*#/) {
			#empty or comment line, do nothing
		}
		elsif (/^([^=]+)=(.*)$/) {
			my $key = normalize($1);
			my $val = normalize($2);
			
			#print STDERR "found $key -> $val!\n";
			
			unless ($val) {
				$val = readMultilineValue($fh);
				#print STDERR "val re-read: `$val'\n";
			}
			
			$result->{$key} = $val;
		}
		else {
			die ("Choked on config line `$_'")
		}
	}
	
	close($fh);
	
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
sub setErrorStatus {
	my ($dbh, $jobId) = @_;
	
	$dbh->do("update trids set is_done = 2 where id = $jobId");
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
	
	# this is commented out for debugging purposes
	#system("rm -r $jobPath");
}

#####
#
#####
sub performCallBack {
	my ($jobId, $origFilename, $resultPath, $errorMessage) = @_;
	
	my $curl = WWW::Curl::Easy->new;

	my $curlForm = WWW::Curl::Form->new;
	$curlForm->formadd("requestID", "" . $jobId);
	$curlForm->formadd("fileName", $origFilename);
	
	if (defined($resultPath)) {
		$curlForm->formaddfile($resultPath, "file", "multipart/form-data");
	}
	else {
		$curlForm->formadd("error", $errorMessage);
	}

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
	
	print "DEBUG: call-back server response:\n$response_body;\n";
}

#####
#
#####
sub checkLangPair {
	my ($conf, $lp) = @_;
	
	my ($srcLang, $tgtLang) = split(/-/, $lp);
	
	my $translHostList = confHash($conf->{'translation host list'});
	my $recaseHostList = confHash($conf->{'recasing host list'});
	
	unless (defined($translHostList->{$lp}) and defined($recaseHostList->{$tgtLang})) {
		die("Failed to locate port for language pair `$lp'/`$tgtLang'");
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
	
	return {map { $_ => $jobPath . "/" . $_ . ".txt" } qw(input tok rawtrans detok toklog detoklog)};
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
	
	return RPC::XML::Client->new($list->{$lp});
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
	
	if ($rawTextMode) {
		return $rawTranslation;
	}
	else {
		my $rawReCased = communicate($config, $proxy, $rawTranslation);
		return finalizeRecasing($rawReCased);
	}
}

#####
#
#####
sub connectDb {
	my ($config) = @_;
	
	my $dbPath = $config->{'db path'};
	my $dbh = DBI->connect("dbi:SQLite:dbname=$dbPath","","");
	
	return $dbh;
}

#####
#
#####
sub reportResults {
	my ($config, $jobId, $tmpNames, $origFilename) = @_;
	
	my $jobPath = $config->{'work dir'} . "/" . $jobId;
	
	# initialize a DB connection
	my $dbh = connectDb($config);
	
	# if the call-back URL is defined, perform call-back
	if (defined($config->{'call-back url'})) {
		performCallBack($jobId, $origFilename, $tmpNames->{'detok'});
		
		#delete the directory and update the status
		cleanup($dbh, $jobId, $jobPath);
	}
	
	# otherwise, save status for retrieval via getresults.php
	else {
		saveStatus($dbh, $jobId);
	}
}

#####
#
#####
sub translate {
	my ($config, $cell, $translProxy, $recaseProxy) = @_;
	
	my $text = $cell->{'text'};
	my $hashToStr = join(", ", map { $_ . ": `" . $cell->{$_} . "'" } sort keys %$cell);
	
	# lower-case
	my $lcText = lowerCase($config, $text);
	
	my $rawOut = undef;
	
	# translate
	eval {
		$rawOut = communicate($config, $translProxy, $lcText);
	};
	
	if ($@ or !$rawOut) {
		die("Failed to translate subtitle ($hashToStr), error message: $@");
	}
	
	# re-case
	my $recasedOut = undef;
	
	eval {
		$recasedOut = reCase($config, $rawOut, $recaseProxy);
	};
	
	if ($@ or !$recasedOut) {
		die("Failed to re-case subtitle ($hashToStr), translation: $rawOut, error message: $@");
	}
	
	# replacing line break symbol with line break
	my $lineBreakReplacement = confBool($config->{"line-breaks"})? "\n": " ";
	$recasedOut =~ s/\Q$LINE_BREAK\E/$lineBreakReplacement/g;
	
	#print "DEBUG: " . join("\n######\n", "", $text, $lcText, $rawOut, $recasedOut, "") . "----\n";
	
	# return the re-cased translation
	return $recasedOut;
}

#####
#
#####
sub complain {
	my ($config, $jobId, $origFilename, $errMsg) = @_;
	
	# display error message
	print "ERROR: $errMsg;\n";
	
	# connect to DB
	my $dbh = connectDb($config);
	
	# update job status to "error"
	setErrorStatus($dbh, $jobId);
	
	# if call-back defined, send back erroneous call-back
	if (defined($config->{'call-back url'})) {
		performCallBack($jobId, $origFilename, undef, $errMsg);
	}
}

#####
#
#####
sub readSubtitles {
	my ($inFh) = @_;
	
	my @rawLines = map { s/[\n\r]//g; $_ } <$inFh>;
	my @result = ();
	
	my $hasTimeCodes = ($rawLines[0] =~ /^\d+(\s+\d{2}(\s*:\s*\d{2}){3}){2}$/);
	
	print "DEBUG has time codes: $hasTimeCodes;\n";
	
	if ($hasTimeCodes) {
		for my $line (@rawLines) {
			
			#time-code
			if ($line =~ /^(\d+)\s+(\d{2}(?:\s*:\s*\d{2}){3})\s+(\d{2}(?:\s*:\s*\d{2}){3})$/) {
				my ($idx, $from, $to) = ($1, $2, $3);
				
				$from =~ s/ //g;
				$to =~ s/ //g;
				
				push @result, { 'timecode' => "$idx\t$from\t$to" };
			}
			
			#empty line ends a subtitle, non-empty lines mean more text
			elsif ($line !~ /^\s*$/) {
				my $delim = "";
				
				if (defined($result[$#result]->{'text'})) {
					$delim = $LINE_BREAK;
				}
				
				$result[$#result]->{'text'} .= $delim . postClean($line);
			}
		}
	}
	else {
		@result = map { {'text' => $_ } } @rawLines;
	}
	
	return @result;
}

#####
#
#####
sub postClean {
	my ($text) = @_;
	
	$text =~ s/[\x00-\x09\x0b\x0c\x0e-\x1f\x7f\x{feff}]//g;
	$text =~ s/\xa0\x9a/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^ //g;
	$text =~ s/ $//g;
	
	return $text;
}

