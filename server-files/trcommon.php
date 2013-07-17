<?php
	# NB! set the path to your config file here:
	#$config = loadConfig("/home/mphi/offweb/SyncAsync/offweb-files/config.ini");
	$config = "fail";
	die("please update trcommon.php with your personal path to the config.ini file, and then comment this line out");
	
	#path to the SQLite DB file
	$dbPath = $config["db path"];

	#base path where translation job directories will be created
	$workDir = $config["work dir"];

	#translation script path
	$trScript = $config["translation script"];

	#support 2 kinds of output -- human-readable and machine-readable
	#$forHumans = isset($_GET['human']);
	$forHumans = 1;
	
	#####
	# prepare a connection to the SQLite database for job ID management
	#####
	function initDb($errorCode) {
		global $dbPath, $forHumans;
		
		#open a connection
		$result = new PDO("sqlite:$dbPath", "", "", array(PDO::ATTR_PERSISTENT => false));
		
		#check if successful
		if (!$result) {
			die($forHumans? "$ERROR_CODE\nfailed to connect to local DB": $errorCode);
		}
		
		return $result;
	}
	
	#####
	# check the status of a job
	#####
	function checkJob($db, $id, $ERROR_CODE) {
		#find out the job status
		$stmt = $db->prepare("select is_done, filename from trids where id = ?")
			or die($forHumans? "$ERROR_CODE\nFailed to prepare statement": $ERROR_CODE);
		$stmt->execute(array($id))
			or die($forHumans? "$ERROR_CODE\nFailed to execute statement": $ERROR_CODE);

		$result = $stmt->fetch();

		#if the job ID has not been registered, report an error
		if (!$result) {
			die($forHumans? "$ERROR_CODE\nNone such job ID registered": $ERROR_CODE);
		}
		
		return $result;
	}
	
	#####
	# clear the job entry
	#####
	function clearJobEntry($db, $id, $ERROR_CODE) {
		#find out the job status
		$stmt = $db->prepare("delete from trids where id = ?")
			or die($forHumans? "$ERROR_CODE\nFailed to prepare statement": $ERROR_CODE);
		
		$stmt->execute(array($id))
			or die($forHumans? "$ERROR_CODE\nFailed to execute statement": $ERROR_CODE);
	}
	
	#####
	#
	#####
	function loadConfig($configFilePath) {
		$result = array();
		
		$fh = @fopen($configFilePath, "r");
		
		if ($fh) {
			while (($buffer = fgets($fh)) !== false) {
				$normBuf = normalize($buffer);
				
				if (strlen($normBuf) == 0 or substr($normBuf, 0, 1) == "#") {
					#empty or comment line, do nothing
				}
				else if (preg_match('/^([^=]+)=(.*)$/', $normBuf, $matches)) {
					$key = trim($matches[1]);
					$value = trim($matches[2]);
					
					if (!$value) {
						$value = readMultilineValue($fh);
					}
					
					$result[$key] = $value;
				}
				else {
					die("Failed to parse config line `$normBuf'");
				}
			}
			if (!feof($fh)) {
				die("Failed to read the config file");
			}
			
			fclose($fh);
		}
		else {
			die("Failed to open the config file ($configFilePath)");
		}
		
		return $result;
	}
	
	#####
	#
	#####
	function readMultilineValue($fh) {
		$val = "";
		
		$buf = fgets($fh);
		$tbuf = trim($buf);
		
		while ($buf !== false and strlen($tbuf) > 0 and substr($tbuf, 0, 1) != "#") {
			$val .= $tbuf . "\n";
			
			$buf = fgets($fh);
			$tbuf = trim($buf);
		}
		
		return $val;
	}
	
	#####
	#
	#####
	function normalize($str) {
		return preg_replace('/\s+/', ' ', trim($str));
	}
	
	#####
	#
	#####
	function confHash($configStr) {
		$lines = explode("\n", $configStr);
		$result = array();
		
		foreach ($lines as $line) {
			if (strlen(trim($line)) > 0) {
				$fields = explode(" ", $line);
				$result[$fields[0]] = $fields[1];
			}
		}
		
		return $result;
	}

	#####
	#
	#####
	function checkMosesServerUp($rawhost) {
		$host = str_replace(array("http://", "https://", "/RPC2"), array("", "", ""), $rawhost);

		$fp = fsockopen($host, -1, $errno, $errstr);
		if ($fp) {
			$query = "POST /RPC2 HTTP/1.0\nUser_Agent: My Client\nHost: ".$host."\nContent-Type: text/xml\nContent-Length: 3\n\nXXX\n";

			if (!fputs($fp, $query, strlen($query))) {
				die("Translation/recasing server is down (1)");
			}

			$contents = '';
			while (!feof($fp)) {
				$contents .= fgets($fp);
			}

			fclose($fp);
			
			if (!$contents) {
				die("Translation/recasing server is down (2)");
			}
		}
		else {
			die("Translation/recasing server is down (3: $host / $errno / $errstr)");
		}
	}

	#####
	#
	#####
	function checkIfServersUp($langPair) {
		global $config;
		
		$langs = explode("-", $langPair);
		$tgtLang = $langs[1];
		
		$trHostHash = confHash($config['translation host list']);
		$rcHostHash = confHash($config['recasing host list']);
		
		checkMosesServerUp($trHostHash[$langPair]);
		checkMosesServerUp($rcHostHash[$tgtLang]);
	}
?>
