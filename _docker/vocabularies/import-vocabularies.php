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

$vocabularies = [
    [
        'o:prefix'        => 'frapo',
        'o:namespace_uri' => 'http://purl.org/cerif/frapo/',
        'o:label'         => 'FRAPO',
        'o:comment'       => 'Funding, Research Administration and Projects Ontology',
        'file'            => $vocabDir . '/frapo.owl',
    ],
    [
        'o:prefix'        => 'fabio',
        'o:namespace_uri' => 'http://purl.org/spar/fabio/',
        'o:label'         => 'FaBiO',
        'o:comment'       => 'FRBR-aligned Bibliographic Ontology',
        'file'            => $vocabDir . '/fabio.owl',
    ],
];

foreach ($vocabularies as $vocab) {
    $file = $vocab['file'];
    unset($vocab['file']);

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
        $rdfImporter->import('file', $vocab, [
            'file'   => $file,
            'format' => 'rdfxml',
        ]);
        fwrite(STDOUT, "[OK]   Imported {$vocab['o:label']}\n");
    } catch (\Exception $e) {
        fwrite(STDERR, "[ERROR] {$vocab['o:label']}: " . $e->getMessage() . "\n");
    }
}
