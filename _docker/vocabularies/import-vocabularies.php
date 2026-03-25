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
    [
        'o:prefix'        => 'geo',
        'o:namespace_uri' => 'http://www.w3.org/2003/01/geo/wgs84_pos#',
        'o:label'         => 'WGS84 Geo',
        'o:comment'       => 'WGS84 Geo Positioning: latitude, longitude, altitude',
        'file'            => $vocabDir . '/geo.rdf',
    ],
    [
        'o:prefix'        => 'marcrel',
        'o:namespace_uri' => 'http://id.loc.gov/vocabulary/relators/',
        'o:label'         => 'MARC Relators',
        'o:comment'       => 'Library of Congress MARC Relator terms for agent roles',
        'file'            => $vocabDir . '/marcrel.rdf',
    ],
    [
        'o:prefix'        => 'dre',
        'o:namespace_uri' => 'http://am-digital.org/ontology/dre/',
        'o:label'         => 'DRE',
        'o:comment'       => 'Digital Research Environment - Africa Multiple custom vocabulary',
        'file'            => $vocabDir . '/dre.owl',
    ],
];

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
