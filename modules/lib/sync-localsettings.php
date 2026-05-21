<?php
/**
 * Update LocalSettings.php variables from panel/env (safe escaping via var_export).
 * Only syncs a whitelist of panel-defined variables.
 * All custom user edits outside the whitelist are preserved.
 * Usage: php sync-localsettings.php /path/to/LocalSettings.php < settings.json
 */
declare(strict_types=1);

// Whitelist of variables allowed to be overridden from the panel.
// Everything else in LocalSettings.php is left alone.
$SYNC_WHITELIST = [
	'wgServer',
	'wgCanonicalServer',
	'wgDBserver',
	'wgDBname',
	'wgDBuser',
	'wgDBpassword',
	'wgSitename',
	'wgLanguageCode',
];

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

	// Only sync whitelisted variables; skip everything else
	if (!in_array($name, $SYNC_WHITELIST, true)) {
		fwrite(STDERR, "sync-localsettings: variable $name not in whitelist; skipping\n");
		continue;
	}

	// Build the replacement statement using var_export for safe PHP literal formatting
	$replacement = var_export($value, true);

	// Match an assignment to the variable (e.g. $wgServer = '...';) capturing leading
	// whitespace so we preserve indentation and any trailing comments.
	$pattern = '/(^[ \t]*\$' . preg_quote($name, '/') . '\s*=\s*)(?:[^;]*);/m';

	if (preg_match($pattern, $content)) {
		// Replace only the RHS while preserving leading whitespace and the semicolon
		$content = preg_replace($pattern, "\\1" . $replacement . ';', $content, 1);
	} else {
		// Do NOT append variables that are not already defined — respect user's custom file
		fwrite(STDERR, "sync-localsettings: variable $name not found in LocalSettings.php; skipping\n");
	}
}

// Create a backup of the existing LocalSettings.php before writing.
$bak = $file . '.bak.' . date('YmdHis');
if (!copy($file, $bak)) {
	fwrite(STDERR, "sync-localsettings: failed to create backup $bak\n");
	exit(1);
}

if (file_put_contents($file, $content) === false) {
	fwrite(STDERR, "sync-localsettings: cannot write file\n");
	// Attempt to restore from backup
	@copy($bak, $file);
	exit(1);
}
