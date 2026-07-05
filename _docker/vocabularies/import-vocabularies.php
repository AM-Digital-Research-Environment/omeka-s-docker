<?php
/**
 * Import custom RDF vocabularies into Omeka S.
 * Called from docker-entrypoint.sh after Omeka S installation.
 *
 * Usage: php import-vocabularies.php <vocab-dir> <omeka-root>
 */

if ($argc < 3) {
    fwrite(STDERR, "Usage: php $argv[0] <vocab-dir> <omeka-root>\n");
    exit(1);
}

$vocabDir = $argv[1];
$omekaRoot = $argv[2];

require $omekaRoot . '/bootstrap.php';

$application = \Omeka\Mvc\Application::init(
    require $omekaRoot . '/application/config/application.config.php'
);
$services = $application->getServiceManager();

// Authenticate as the first global_admin so the API allows writes.
$auth = $services->get('Omeka\AuthenticationService');
$entityManager = $services->get('Omeka\EntityManager');
$admin = $entityManager
    ->getRepository('Omeka\Entity\User')
    ->findOneBy(['role' => 'global_admin']);
if ($admin) {
    $auth->getStorage()->write($admin);
}

$rdfImporter = $services->get('Omeka\RdfImporter');

// Vocabularies are declared in JSON manifests (*.json) inside the vocab dir,
// each an array of {prefix, namespace_uri, label, comment, file[, label_property]}
// entries with `file` relative to the manifest. The base image bakes
// vocabularies.json (generic vocabularies); deployment overlays can bind-mount
// additional manifest + ontology pairs into the same directory (e.g.
// compose.amira.yml adds dre.json + dre.owl).
$vocabularies = [];
$manifests = glob($vocabDir . '/*.json') ?: [];
sort($manifests);
foreach ($manifests as $manifest) {
    $entries = json_decode((string) file_get_contents($manifest), true);
    if (!is_array($entries)) {
        fwrite(STDERR, "[WARN] Skipping invalid manifest: $manifest\n");
        continue;
    }
    foreach ($entries as $entry) {
        if (!isset($entry['prefix'], $entry['namespace_uri'], $entry['label'], $entry['file'])) {
            fwrite(STDERR, "[WARN] Incomplete vocabulary entry in $manifest\n");
            continue;
        }
        $vocab = [
            'o:prefix'        => $entry['prefix'],
            'o:namespace_uri' => $entry['namespace_uri'],
            'o:label'         => $entry['label'],
            'o:comment'       => $entry['comment'] ?? '',
            'file'            => dirname($manifest) . '/' . $entry['file'],
        ];
        if (!empty($entry['label_property'])) {
            $vocab['label_property'] = $entry['label_property'];
        }
        $vocabularies[] = $vocab;
    }
}

foreach ($vocabularies as $vocab) {
    $file = $vocab['file'];
    unset($vocab['file']);

    $labelProperty = $vocab['label_property'] ?? null;
    unset($vocab['label_property']);

    // Check if already imported.
    $existing = $entityManager
        ->getRepository('Omeka\Entity\Vocabulary')
        ->findOneBy(['namespaceUri' => $vocab['o:namespace_uri']]);
    if ($existing) {
        fwrite(STDOUT, "[SKIP] {$vocab['o:prefix']} already imported.\n");
        continue;
    }

    if (!file_exists($file)) {
        fwrite(STDERR, "[WARN] File not found: $file\n");
        continue;
    }

    try {
        $options = [
            'file'   => $file,
            'format' => 'rdfxml',
        ];
        if ($labelProperty) {
            $options['label_property'] = $labelProperty;
        }
        $rdfImporter->import('file', $vocab, $options);
        fwrite(STDOUT, "[OK]   Imported {$vocab['o:label']}\n");
    } catch (\Exception $e) {
        fwrite(STDERR, "[ERROR] {$vocab['o:label']}: " . $e->getMessage() . "\n");
    }
}
