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

use threads;
use threads::shared;

use URI::Escape;
use JSON;
use Data::Dumper;

#requires perl 5.10+
use feature 'state';

use IPC::Open2;

binmode(STDOUT, ':utf8');

our $LINE_BREAK = " _br_ ";

our $RECASER_LAST_LINE_ENDED_WITH_PUNCT = 1;

print "starting translation\n";

# load command-line arguments: language pair, job numeric ID, filename of the submitted file
my ($langPair, $jobId, $origFilename) = @ARGV;

# load configuration
my $config = confLoad($Bin . "/config.ini");

unless (confBool($config->{"line-breaks"})) {
	$LINE_BREAK = " ";
}

# exception handling: in case of exceptions update status to error and/or perform an error call-back
eval {
	# main file processing (tokenization, translation, reporting, etc.) is done here
	processFile($langPair, $jobId, $origFilename, $config);
};

# if an error has occured, report it
if ($@) {
	complain($config, $jobId, $origFilename, $@);
}

print "finished\n";

#####################################################
sub processFile {
	my ($langPair, $jobId, $origFilename, $config) = @_;

	# check if the language pair is set up in the configuration
	if (! defined($config->{"smartmate_translate"})) {
	    checkLangPair($config, $langPair);
	}

	# initialize filenames for intermediate files
	my $tmpFilenames = initTmpFilenames($config, $jobId);
	
	# tokenize input using the configurated external script
	my $fileToTranslate = doTokenization($config, $tmpFilenames, $langPair);
	
	if (confBool($config->{'do truecasing'})) {
		$fileToTranslate = doTrueCasing($config, $tmpFilenames, $langPair);
	}

	##### translate and re-case input #####

	# prepare proxies for translation and re-casing
	my $translProxy = getProxy($config, 'translation host list', $langPair);
	
	# create a user agent to be able to handle https, but only if using SmartMATE
	my $ua = 0;
	if (defined($config->{"smartmate_translate"}) and $config->{'smartmate_translate'}) {
		$ua = LWP::UserAgent->new();
	}
	
	my ($srcLang, $tgtLang) = split(/-/, $langPair);
	my $recaseProxy = undef;
	unless (confBool($config->{'do truecasing'})) {
		$recaseProxy = getProxy($config, 'recasing host list', $tgtLang);
	}

	# open input and output files
	
	my $inFh = fopen($fileToTranslate);
	my @subs = readSubtitles($inFh);
	close($inFh);
	
	translateSubtitles(\@subs, $tmpFilenames->{'transl'}, $config, $translProxy, $recaseProxy, $langPair, $ua, $jobId);

	# de-tokenize output using the configurated external script
	doDeTokenization($config, $tmpFilenames, $langPair);
	
	# convert to dos or unix into "output.txt" as a final step
	finalizeLineEndings($config, $tmpFilenames);
	
	# convert to srt
	generateSrtFile($config, $tmpFilenames);

	# report results by either performing a call-back (if the host is configured) or by updating the job the status
	if ($origFilename) {
		reportResults($config, $jobId, $tmpFilenames, $origFilename, scalar @subs);
	}
}

#####
#
#####
sub translateSubtitles {
	my ($subs, $outfile, $config, $translProxy, $recaseProxy, $langPair, $ua, $jobId) = @_;
	
	#my $subs = shared_clone($nonsharedSubs);
	
	my $t0 = gettime();
	
	my $outFh = fopen(">" . $outfile);
	
	my $maxThreads = 0 + $config->{'max threads'};
	if ($maxThreads < 1) {
		$maxThreads = 1;
	}
	
	my $cellCount = 0;
	my $cellTotal = scalar @$subs;
	
	print "DEBUG max threads: $maxThreads\n";
	
	for my $cell (@$subs) {
		# perform lower-casing or true-casing, translation and re-casing or de-true-casing
		
		my $countThreads = scalar threads->list(threads::running);
		
		while ($countThreads > $maxThreads) {
			#sleep 0.1 seconds
			select(undef, undef, undef, 0.1);
			
			$countThreads = scalar threads->list(threads::running);
		}
		
		$cellCount++;
		
		#every 32 subtitles
		unless ($cellCount & 0b11111) {
			reportProgress($config, $jobId, $cellTotal, $cellCount);
		}
		
		$cell->{'thread'} = threads->create(\&translateOneSubtitle, $config, $cell, $translProxy, $recaseProxy, $langPair, $ua);
		#$cell->{'output'} = finalizeRecasing(translateOneSubtitle($config, $cell, $translProxy, $recaseProxy, $langPair, $ua));
	}
		
	for my $cell (@$subs) {
		$cell->{'output'} = finalizeRecasing($cell->{'thread'}->join());
		displayResults($outFh, $cell);
	}
	
	close($outFh);

	my $t1 = gettime();
	
	print "DEBUG total translation time: " . ($t1 - $t0) . "; #subs: " . (scalar @$subs) . "\n";
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
	my ($outFh, $cell) = @_;
	
	my $timeCodedOutput = (defined($cell->{'timecode'}));
	
	print $outFh 
		($timeCodedOutput? $cell->{'timecode'} . "\n": "") .
		$cell->{'output'} . "\n" .
		($timeCodedOutput? "\n": "");
}

#####
#
#####
sub smartmate_translate {
	my ($config, $inputText, $langPair, $ua) = @_;
	
	if ($inputText =~ /^\s*$/) {
		return $inputText;
	}
	
	unless (defined($config->{'engine list'})) {
		die("SmartMATE engineOID list not found in config file");
	}
	
	my $enginesList = confHash($config->{'engine list'});
	
	unless (defined($enginesList->{$langPair})) {
		die("SmartMATE engineOID for `$langPair' not found in config file");
	}
	
	unless (defined($config->{"smartmate_base_url"})) {
		die("SmartMATE base API URL not found in config file");
	}
	
	my $url = $config->{"smartmate_base_url"};
	
	$url .= "&engineOID=".$enginesList->{$langPair};
	$url .= "&q=";

	$inputText =~ s/[\r\n]//g;

	my $encoded = uri_escape(Encode::encode("utf8", $inputText));

	print "translating\n";
	my $done = 0;
	my $result;
	while (!$done) {
		$result = $ua->get($url.$encoded) or die;
#		print Dumper($result);
		print $result->code()."\n";
		my $json = $result->content;
		#$json =~ s/^\s+//;
		#$json =~ s/\s+$//;
		#print $json."\n";
		$json = decode_json($json);
		if ($json->{'success'}) {
			$result=$json->{'translation'};
			$done = 1;
		} else {
			sleep(10);
		}
	}

	if (defined($config->{'post processing list'})) {
	    state $ppList = confHash($config->{'post processing list'});
	    if (defined($ppList->{$langPair})) {
	     	state $ppCmd = $ppList->{$langPair};
	     	#state requires Perl 5.10+
	     	state ($ppIn, $ppOut);
	     	state $ppPipe = open2($ppOut, $ppIn, $ppCmd);
	     	print $ppIn Encode::encode("utf8", $result)."\n";
	     	$ppIn->flush();
	     	$result = Encode::decode("utf8", <$ppOut>);
	     	chomp $result;
	    }
	}

	#chomp $result;

	return $result;

}

#####
#
#####
sub communicate {
	my ($config, $proxy, $inputText, $langPair, $ua) = @_;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
	if ($rawTextMode) {
		if (defined($config->{"smartmate_translate"}) and  $config->{"smartmate_translate"}) {
			return smartmate_translate($config, $inputText, $langPair, $ua);
		} else {
			die("raw text mode communication not implemented yet");
		}
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
		elsif (ref($response) ne "RPC::XML::struct") {
			die "Proxy returned an error: $response;";
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
	my $nextUp = $RECASER_LAST_LINE_ENDED_WITH_PUNCT;
	
	# upper-case words after punctuation
	for my $inWord (@inWords) {
		push @outWords, ($nextUp? ucfirst($inWord): $inWord);
		
		$nextUp = ($inWord =~ /^[.?!]$/)
	}
	
	$RECASER_LAST_LINE_ENDED_WITH_PUNCT = $inWords[$#inWords] =~ /[.?!]/;
	
	# upper-case words after dialogue dashes
	for my $i (1..$#outWords) {
		if ($outWords[$i - 1] eq "-" and ($i == 1 or $outWords[$i - 2] eq "_br_")) {
			$outWords[$i] = ucfirst($outWords[$i]);
		}
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
sub reportProgress {
	my ($config, $jobId, $numTotal, $numDone) = @_;
	
	my $curl = WWW::Curl::Easy->new;

	my $curlForm = WWW::Curl::Form->new;
	$curlForm->formadd("requestID", "" . $jobId);
	$curlForm->formadd("totalSubs", "" . $numTotal);
	$curlForm->formadd("completedSubs", "" . $numDone);

	$curl->setopt(CURLOPT_HTTPPOST, $curlForm);

	$curl->setopt(CURLOPT_HEADER, 1);
	$curl->setopt(CURLOPT_URL, $config->{'call-back url'});

	my $response_body;
	$curl->setopt(CURLOPT_WRITEDATA, \$response_body);

	# Starts the actual request
	my $retcode = $curl->perform;
	
	unless ($retcode == 0) {
		die("An error happened at progress update: $retcode " .
			$curl->strerror($retcode) . "; " . $curl->errbuf . "\n");
	}
	
	print "DEBUG: progress update server response:\n$response_body;\n";
}

#####
#
#####
sub performCallBack {
	my ($jobId, $origFilename, $resultPaths, $errorMessage, $numTotal) = @_;
	
	my $curl = WWW::Curl::Easy->new;

	my $curlForm = WWW::Curl::Form->new;
	$curlForm->formadd("requestID", "" . $jobId);
	$curlForm->formadd("totalSubs", "" . $numTotal);
	$curlForm->formadd("completedSubs", "" . $numTotal);
	$curlForm->formadd("fileName", $origFilename);
	$curlForm->formadd("error", $errorMessage);
	
	if (defined($resultPaths)) {
		#print "adding file\n";
		$curlForm->formaddfile($resultPaths->{'output'}, "file", "multipart/form-data");
		#print "adding srt file too\n";
		$curlForm->formaddfile($resultPaths->{'srt'}, "srtfile", "multipart/form-data");
	}

	$curl->setopt(CURLOPT_HTTPPOST, $curlForm);

	$curl->setopt(CURLOPT_HEADER, 1);
	$curl->setopt(CURLOPT_URL, $config->{'call-back url'});
#	$curl->setopt(CURLOPT_URL, $config->{'smartmate_test'});
#	$curl->setopt(CURLOPT_SSL_VERIFYHOST, 0);
#	$curl->setopt(CURLOPT_SSL_VERIFYPEER, 0); 
	

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
	# tok = tokenized file
	# truecase = true-cased tokenized file
	# transl = translated, re-cased file
	# detok = de-tokenized file
	# output = final output file
	
	# toklog = log file of the tokenizer
	# detoklog = log file of the de-tokenizer
	
	my $result = {map { $_ => $jobPath . "/" . $_ . ".txt" } qw(input tok truecase transl detok output toklog detoklog truecaselog)};
	$result->{'srt'} = $jobPath . "/" . "output.srt";
	return $result;
}

#####
#
#####
sub doTokenization {
	my ($config, $tmpNames, $langPair) = @_;
	
	my $resultFilename = $tmpNames->{'tok'};
	
	# if in raw text mode, skip tokenization
	if (confBool($config->{'raw text mode'})) {
		$resultFilename = $tmpNames->{'input'};
	}
	else {
		my ($srcLang) = split(/-/, $langPair);
		
		my $tokScript = $config->{'tokenizer'};
		my $toUnixScript = $Bin . "/tounix.pl";
		
		#convert (just in case) from CRLF to LF and then tokenize
		system(sprintf("%s < %s | %s -l %s > %s 2> %s",
			$toUnixScript,
			$tmpNames->{'input'},
			$tokScript,
			$srcLang,
			$tmpNames->{'tok'},
			$tmpNames->{'toklog'}));
		
		unless ($? == 0) {
			die("Failed to tokenize file ($!)");
		}
	}
	
	unless (-e $resultFilename) {
		die("Tokenized file (`$resultFilename') was not generated");
	}
	
	return $resultFilename;
}

#####
#
#####
sub doTrueCasing {
	my ($config, $tmpNames, $langPair) = @_;
	
	my $resultFilename = $tmpNames->{'truecase'};
	
	# if in raw text mode, skip tokenization
	if (confBool($config->{'raw text mode'})) {
		$resultFilename = $tmpNames->{'input'};
	}
	else {
		my ($srcLang) = split(/-/, $langPair);
		
		my $modelHash = confHash($config->{'truecaser model list'});
		my $modelPath = $modelHash->{$srcLang};
		
		unless ($modelPath) {
			die("True-casing is turned on, but the model path for the language `$srcLang' is not set");
		}
		
		my $truecaserPath = $Bin . "/subs-truecase.pl";
		
		system(sprintf("%s --model %s < %s > %s 2> %s",
			$truecaserPath,
			$modelPath,
			$tmpNames->{'tok'},
			$tmpNames->{'truecase'},
			$tmpNames->{'truecaselog'}));
		
		my $status = $?;
		my $msg = $!;
		
		unless ($? == 0) {
			die("Failed to true-case file ($status / $msg)");
		}
	}
	
	unless (-e $resultFilename) {
		die("True-cased file (`$resultFilename') was not generated");
	}
	
	return $resultFilename;
}

#####
#
#####
sub doDeTokenization {
	my ($config, $tmpNames, $langPair) = @_;
	
	my $rawTextMode = confBool($config->{'raw text mode'});
	
	# if in raw text mode, skip de-tokenization
	if ($rawTextMode) {
		$tmpNames->{'detok'} = $tmpNames->{'transl'};
	}
	else {
		my ($srcLang, $tgtLang) = split(/-/, $langPair);
		
		my $detokScript = $config->{'detokenizer'};
		my $toUnixScript = $Bin . "/tounix.pl";
		
		system(sprintf("%s -l %s < %s > %s 2> %s",
			$detokScript,
			$tgtLang,
			$tmpNames->{'transl'},
			$tmpNames->{'detok'},
			$tmpNames->{'detoklog'}));
		
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
sub finalizeLineEndings {
	my ($config, $tmpFilenames) = @_;
	
	my $finScript = $Bin . "/" . (confBool($config->{'crlf line endings'})? "todos": "tounix") . ".pl";
	
	my $cmd = sprintf("%s < %s > %s", $finScript, $tmpFilenames->{'detok'}, $tmpFilenames->{'output'});
	
	system($cmd);
}

#####
#
#####
sub generateSrtFile {
	my ($config, $tmpFilenames) = @_;
	
	my $convScript = $Bin . "/txt2srt.pl";
	
	my $cmd = sprintf("%s < %s | iconv -c -f utf8 -t cp1252 > %s", $convScript, $tmpFilenames->{'output'}, $tmpFilenames->{'srt'});
	
	system($cmd);
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
	my ($config, $text, $langPair) = @_;
	
	if (confBool($config->{'raw text mode'}) or confBool($config->{'do truecasing'})) {
		return $text;
	}
	else {
		return lc($text);
	}
}

#####
#
#####
sub restoreCase {
	my ($config, $rawTranslation, $proxy) = @_;
	
	if (confBool($config->{'raw text mode'})) {
		return $rawTranslation;
	}
	else {
		my $almostFinalResult = $rawTranslation;
		
		unless (confBool($config->{'do truecasing'})) {
			$almostFinalResult = communicate($config, $proxy, $rawTranslation);
		}
		
		#my $finalResult = finalizeRecasing($almostFinalResult);
		
		#return $finalResult;
		return $almostFinalResult;
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
	my ($config, $jobId, $tmpNames, $origFilenamei, $totalNum) = @_;
	
	my $jobPath = $config->{'work dir'} . "/" . $jobId;
	
	# if the call-back URL is defined, perform call-back
	if (defined($config->{'call-back url'})) {
		performCallBack($jobId, $origFilename, $tmpNames, undef, $totalNum);
		
		# initialize a DB connection
		my $dbh = connectDb($config);
		
		#delete the directory and update the status
		cleanup($dbh, $jobId, $jobPath);
	}
	
	# otherwise, save status for retrieval via getresults.php
	else {
		# initialize a DB connection
		my $dbh = connectDb($config);
		
		saveStatus($dbh, $jobId);
	}
}

#####
#
#####
sub translateOneSubtitle {
	my ($config, $cell, $translProxy, $recaseProxy, $langPair, $ua) = @_;
	
	my $text = $cell->{'text'};
	my $hashToStr = join(", ", map { $_ . ": `" . $cell->{$_} . "'" } sort keys %$cell);
	
	# lower-case
	my $prepText = lowerCase($config, $text);
	
	my $rawOut = undef;
	
	# translate
	eval {
		$rawOut = communicate($config, $translProxy, $prepText, $langPair, $ua);
	};
	
	if ($@ or (!$rawOut and $prepText !~ /^\s*$/ ) ) {
		die("Failed to translate subtitle ($hashToStr), error message: $@");
	}
	
	# re-case
	my $recasedOut = undef;
	
	eval {
		$recasedOut = restoreCase($config, $rawOut, $recaseProxy);
	};
	
	if ($@ or (!$recasedOut and $rawOut !~ /^\s*$/) ) {
		die("Failed to re-case subtitle ($hashToStr), translation: $rawOut, error message: $@");
	}
	
	# replacing line break symbol with line break
	my $lineBreakReplacement = confBool($config->{"line-breaks"})? "\n": " ";
	$recasedOut =~ s/\Q$LINE_BREAK\E/$lineBreakReplacement/g;
	
	#print "DEBUG: " . join(" ###### ", "", $text, $prepText, $rawOut, $recasedOut, "") . "----\n";
	
	if ($cell->{'lines'} and scalar(@{$cell->{'lines'}}) == 2 and $cell->{'lines'}->[0] =~ /^-/ and $cell->{'lines'}->[1] =~ /^-/ and $recasedOut =~ /^(-.*)(-.*)$/) {
		$recasedOut = $1 . "\n" . $2;
	}
	
	$recasedOut =~ s/\(\.{3}\) \(\.{3}\)/\1\n\2/g;
	
	# return the re-cased translation
	#$cell->{'output'} = $recasedOut;
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
		performCallBack($jobId, $origFilename, undef, $errMsg, 0);
	}
}

#####
#
#####
sub readSubtitles {
	my ($inFh) = @_;
	
	my @rawLines = map { s/[\n\r]//g; $_ } <$inFh>;
	my @result = ();
	
	my $hasTimeCodes = ($rawLines[0] =~ /^\d+(\s+\d{2}(\s*:\s*\d{2}){3}){2}\s*$/);
	
	print "DEBUG has time codes: $hasTimeCodes;\n";
	
	if ($hasTimeCodes) {
		for my $line (@rawLines) {
			
			#time-code
			if ($line =~ /^(\d+)\s+(\d{2}(?:\s*:\s*\d{2}){3})\s+(\d{2}(?:\s*:\s*\d{2}){3})\s*$/) {
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
				
				my $cleanLine = postClean($line);
				$result[$#result]->{'text'} .= $delim . $cleanLine;
				push @{$result[$#result]->{'lines'}}, $cleanLine;
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

