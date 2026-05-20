<?php
/**
 * Update LocalSettings.php variables from panel/env (safe escaping via var_export).
 * Usage: php sync-localsettings.php /path/to/LocalSettings.php < settings.json
 */
declare(strict_types=1);

$file = $argv[1] ?? '';
if ($file === '' || !is_readable($file)) {
	fwrite(STDERR, "sync-localsettings: missing or unreadable file\n");
	exit(1);
}

$json = stream_get_contents(STDIN);
if ($json === false || $json === '') {
	fwrite(STDERR, "sync-localsettings: empty JSON on stdin\n");
	exit(1);
}

$vars = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
if (!is_array($vars)) {
	fwrite(STDERR, "sync-localsettings: invalid JSON object\n");
	exit(1);
}

$content = file_get_contents($file);
if ($content === false) {
	fwrite(STDERR, "sync-localsettings: cannot read file\n");
	exit(1);
}

foreach ($vars as $name => $value) {
	if (!is_string($name) || !preg_match('/^[a-zA-Z_][a-zA-Z0-9_]*$/', $name)) {
		continue;
	}
	$line = '$' . $name . ' = ' . var_export($value, true) . ';';
	$pattern = '/^\$' . preg_quote($name, '/') . '\s*=.*/m';
	if (preg_match($pattern, $content)) {
		$content = preg_replace($pattern, $line, $content);
	} else {
		$content = rtrim($content) . "\n" . $line . "\n";
	}
}

if (file_put_contents($file, $content) === false) {
	fwrite(STDERR, "sync-localsettings: cannot write file\n");
	exit(1);
}
