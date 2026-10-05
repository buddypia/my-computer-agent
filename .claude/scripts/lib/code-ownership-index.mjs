import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
} from 'node:fs';
import {
  basename,
  dirname,
  join,
  relative,
  resolve,
} from 'node:path';

export const CODE_OWNERSHIP_INDEX_SCHEMA_VERSION = '1.0';

export const VIOLATION_CODES = Object.freeze({
  DOMAIN_MAP_MISSING: 'DOMAIN_MAP_MISSING',
  FEATURE_DOC_UNREGISTERED: 'FEATURE_DOC_UNREGISTERED',
  REGISTERED_FEATURE_DOC_MISSING: 'REGISTERED_FEATURE_DOC_MISSING',
  SRC_DIR_MISSING: 'SRC_DIR_MISSING',
  RELATED_FILE_MISSING: 'RELATED_FILE_MISSING',
  UNMAPPED_SOURCE_ARTIFACT: 'UNMAPPED_SOURCE_ARTIFACT',
});

const DEFAULT_PATHS = Object.freeze({
  source_root: 'src',
  features: 'src/features',
  shared: 'src/shared',
  docs_features: 'docs/features',
  tests_unit: 'tests/unit',
});

const DEFAULT_IGNORES = new Set([
  '.git',
  '.worktrees',
  'node_modules',
  'coverage',
  'playwright-report',
  'test-results',
  'output',
]);

const ROUTE_FILE_RE = /(^page|^route|\+page|\+server)\.(ts|tsx|js|jsx|svelte)$/;
const SCHEMA_FILE_RE = /(\.schema\.json|schema\.(ts|tsx|js|mjs|cjs)|schemas?\/.+\.(json|ts|tsx|js|mjs|cjs))$/;
const CONTRACT_FILE_RE = /(contracts?\/|openapi|api[-_]contract|contract\.(json|ya?ml|ts|js))/;
const MIGRATION_FILE_RE = /(migrations?\/|schema\.prisma|drizzle\/|supabase\/migrations)/;

function safeReadJson(filePath, fallback = null) {
  try {
    if (!existsSync(filePath)) return fallback;
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function isObject(v) {
  return Boolean(v) && typeof v === 'object' && !Array.isArray(v);
}

function isNonEmptyString(v) {
  return typeof v === 'string' && v.trim().length > 0;
}

function asArray(v) {
  return Array.isArray(v) ? v : [];
}

function unique(values, limit = Infinity) {
  const out = [];
  const seen = new Set();
  for (const value of values.flat(Infinity)) {
    if (!isNonEmptyString(value)) continue;
    const normalized = normalizeRel(value);
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    out.push(normalized);
    if (out.length >= limit) break;
  }
  return out;
}

function normalizeRel(p) {
  return String(p || '')
    .replace(/\\/g, '/')
    .replace(/^\.\//, '')
    .replace(/\/+/g, '/')
    .replace(/\/$/, '')
    .trim();
}

function toProjectRel(projectDir, absOrRel) {
  const s = normalizeRel(absOrRel);
  if (!s) return '';
  if (s.startsWith('/')) return normalizeRel(relative(projectDir, s));
  return s;
}

function isGlobLike(p) {
  return /[*?[\]{}]/.test(String(p || ''));
}

function existsRel(projectDir, relPath) {
  if (!relPath || isGlobLike(relPath)) return null;
  return existsSync(join(projectDir, relPath));
}

function isDirRel(projectDir, relPath) {
  try {
    return statSync(join(projectDir, relPath)).isDirectory();
  } catch {
    return false;
  }
}

function loadProjectConfig(projectDir) {
  const config = safeReadJson(join(projectDir, 'project-config.json'), null);
  const paths = { ...DEFAULT_PATHS, ...(isObject(config?.paths) ? config.paths : {}) };
  return {
    raw: config,
    present: Boolean(config),
    paths,
  };
}

function walkFiles(rootDir, options = {}) {
  const {
    maxFiles = 2000,
    ignoreDirs = DEFAULT_IGNORES,
    include = () => true,
  } = options;
  const out = [];

  function walk(dir) {
    if (out.length >= maxFiles) return;
    let entries = [];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (out.length >= maxFiles) return;
      if (ignoreDirs.has(entry.name)) continue;
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile() && include(full)) {
        out.push(full);
      }
    }
  }

  if (existsSync(rootDir)) walk(rootDir);
  return out;
}

function featureFolders(projectDir, docsFeaturesPath) {
  const abs = join(projectDir, docsFeaturesPath);
  try {
    return readdirSync(abs, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && /^[0-9]{3}-[a-z0-9-]+$/.test(entry.name))
      .map((entry) => entry.name)
      .sort();
  } catch {
    return [];
  }
}

function specPaths(projectDir, docsFeaturesPath, featureId) {
  const dir = join(projectDir, docsFeaturesPath, featureId);
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && /^SPEC.*\.md$/.test(entry.name))
      .map((entry) => normalizeRel(join(docsFeaturesPath, featureId, entry.name)))
      .sort();
  } catch {
    return [];
  }
}

function flattenPathValues(value) {
  const out = [];
  function visit(v) {
    if (isNonEmptyString(v)) {
      if (looksLikePath(v)) out.push(v);
      return;
    }
    if (Array.isArray(v)) {
      for (const item of v) visit(item);
      return;
    }
    if (isObject(v)) {
      if (isNonEmptyString(v.path)) visit(v.path);
      for (const item of Object.values(v)) visit(item);
    }
  }
  visit(value);
  return unique(out);
}

function looksLikePath(v) {
  const s = String(v);
  return s.includes('/') || /\.[a-z0-9]{1,8}$/i.test(s) || s.includes('{FEATURES_DIR}');
}

function substituteKnownPlaceholders(pathValue, paths) {
  return normalizeRel(pathValue)
    .replaceAll('{FEATURES_DIR}', paths.features)
    .replaceAll('{SHARED_DIR}', paths.shared || DEFAULT_PATHS.shared)
    .replaceAll('{TESTS_DIR}', paths.tests_unit || DEFAULT_PATHS.tests_unit)
    .replaceAll('{DOCS_DIR}', paths.docs_features || DEFAULT_PATHS.docs_features)
    .replaceAll('{SOURCE_ROOT}', paths.source_root || DEFAULT_PATHS.source_root);
}

function progressFiles(context) {
  const details = context?.progress?.details;
  if (!isObject(details)) return [];
  return Object.values(details).flatMap((entry) => asArray(entry?.files));
}

function featureSearchText(feature, domain, context) {
  return [
    feature.id,
    feature.title,
    feature.domain,
    domain?.name,
    domain?.responsibility,
    asArray(domain?.keywords).join(' '),
    context?.title,
    context?.why,
    asArray(context?.success_criteria).join(' '),
    asArray(context?.constraints).join(' '),
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
}

function makeArtifact({ kind, path, featureId = null, source = null, exists = null }) {
  return {
    kind,
    path: normalizeRel(path),
    feature_id: featureId,
    source,
    exists,
  };
}

function addArtifact(artifacts, artifact) {
  if (!artifact.path) return;
  const key = `${artifact.kind}:${artifact.path}:${artifact.feature_id || ''}`;
  if (artifacts._seen.has(key)) return;
  artifacts._seen.add(key);
  artifacts.push(artifact);
}

function activeFeature(feature) {
  return !['archived', 'deprecated'].includes(String(feature?.status || '').toLowerCase());
}

function collectConfiguredArtifactRoots(projectDir, paths) {
  const roots = [];
  const maybe = [
    ['contract', paths.contracts],
    ['schema', paths.schemas],
    ['schema', paths.db_schema],
    ['migration', paths.migrations],
  ];
  for (const [kind, rel] of maybe) {
    if (isNonEmptyString(rel) && existsSync(join(projectDir, rel))) {
      roots.push({ kind, rel: normalizeRel(rel) });
    }
  }
  if (existsSync(join(projectDir, 'contracts'))) roots.push({ kind: 'contract', rel: 'contracts' });
  return roots;
}

function discoverRouteArtifacts(projectDir, paths) {
  const candidates = unique([
    join(paths.source_root || DEFAULT_PATHS.source_root, 'app'),
    join(paths.source_root || DEFAULT_PATHS.source_root, 'routes'),
    join(paths.source_root || DEFAULT_PATHS.source_root, 'pages'),
    'app',
    'pages',
  ]);
  const out = [];
  for (const relRoot of candidates) {
    const absRoot = join(projectDir, relRoot);
    if (!existsSync(absRoot)) continue;
    for (const abs of walkFiles(absRoot, {
      include: (full) => ROUTE_FILE_RE.test(basename(full)),
      maxFiles: 1000,
    })) {
      out.push(makeArtifact({ kind: 'route', path: relative(projectDir, abs), source: 'filesystem', exists: true }));
    }
  }
  return out;
}

function discoverConfiguredArtifacts(projectDir, paths) {
  const out = [];
  for (const root of collectConfiguredArtifactRoots(projectDir, paths)) {
    for (const abs of walkFiles(join(projectDir, root.rel), { maxFiles: 2000 })) {
      const rel = normalizeRel(relative(projectDir, abs));
      let kind = root.kind;
      if (MIGRATION_FILE_RE.test(rel)) kind = 'migration';
      else if (CONTRACT_FILE_RE.test(rel)) kind = 'contract';
      else if (SCHEMA_FILE_RE.test(rel)) kind = 'schema';
      out.push(makeArtifact({ kind, path: rel, source: 'filesystem', exists: true }));
    }
  }
  return out;
}

function buildFeaturePathIndex(features) {
  const byRelated = new Map();
  const srcDirs = [];
  const docDirs = [];
  for (const feature of features) {
    for (const p of feature.related_files || []) byRelated.set(normalizeRel(p), feature.id);
    if (isNonEmptyString(feature.src_dir)) srcDirs.push({ featureId: feature.id, path: normalizeRel(feature.src_dir) });
    if (isNonEmptyString(feature.doc_dir)) docDirs.push({ featureId: feature.id, path: normalizeRel(feature.doc_dir) });
  }
  return { byRelated, srcDirs, docDirs };
}

function mapArtifactToFeature(artifact, pathIndex) {
  const p = normalizeRel(artifact.path);
  if (artifact.feature_id) return artifact.feature_id;
  if (pathIndex.byRelated.has(p)) return pathIndex.byRelated.get(p);
  for (const item of pathIndex.srcDirs) {
    if (p === item.path || p.startsWith(`${item.path}/`)) return item.featureId;
  }
  for (const item of pathIndex.docDirs) {
    if (p === item.path || p.startsWith(`${item.path}/`)) return item.featureId;
  }
  return null;
}

function reverseLookup(artifacts) {
  const fileToFeature = {};
  const routeToFeature = {};
  const schemaToFeature = {};
  const contractToFeature = {};
  const migrationToFeature = {};
  for (const artifact of artifacts) {
    if (!artifact.feature_id) continue;
    fileToFeature[artifact.path] = artifact.feature_id;
    if (artifact.kind === 'route') routeToFeature[artifact.path] = artifact.feature_id;
    if (artifact.kind === 'schema') schemaToFeature[artifact.path] = artifact.feature_id;
    if (artifact.kind === 'contract') contractToFeature[artifact.path] = artifact.feature_id;
    if (artifact.kind === 'migration') migrationToFeature[artifact.path] = artifact.feature_id;
  }
  return {
    file_to_feature: fileToFeature,
    route_to_feature: routeToFeature,
    schema_to_feature: schemaToFeature,
    contract_to_feature: contractToFeature,
    migration_to_feature: migrationToFeature,
  };
}

export function buildCodeOwnershipIndex(projectDir = process.cwd(), options = {}) {
  const root = resolve(projectDir);
  const projectConfig = loadProjectConfig(root);
  const paths = projectConfig.paths;
  const docsFeaturesPath = normalizeRel(paths.docs_features || DEFAULT_PATHS.docs_features);
  const domainMapPath = normalizeRel(join(docsFeaturesPath, 'domain-map.json'));
  const domainMap = safeReadJson(join(root, domainMapPath), null);
  const warnings = [];

  if (!domainMap) {
    warnings.push({
      code: VIOLATION_CODES.DOMAIN_MAP_MISSING,
      detail: `${domainMapPath} is missing or invalid; ownership index is partial.`,
    });
  }

  const domains = asArray(domainMap?.domains);
  const registryFeatures = asArray(domainMap?.features);
  const domainsById = new Map(domains.filter((d) => isNonEmptyString(d?.id)).map((d) => [d.id, d]));
  const registryById = new Map(registryFeatures.filter((f) => isNonEmptyString(f?.id)).map((f) => [f.id, f]));
  const folders = featureFolders(root, docsFeaturesPath);
  const featureIds = unique([...registryById.keys(), ...folders]).sort();
  const artifacts = [];
  artifacts._seen = new Set();
  const features = [];

  for (const id of featureIds) {
    const registry = registryById.get(id) || {};
    const docDir = normalizeRel(join(docsFeaturesPath, id));
    const contextPath = normalizeRel(join(docDir, 'CONTEXT.json'));
    const context = safeReadJson(join(root, contextPath), null);
    const specs = specPaths(root, docsFeaturesPath, id);
    const srcDir = isNonEmptyString(registry.src_dir)
      ? normalizeRel(join(paths.features || DEFAULT_PATHS.features, registry.src_dir))
      : null;
    const related = unique([
      ...flattenPathValues(context?.references?.related_code).map((p) => substituteKnownPlaceholders(p, paths)),
      ...progressFiles(context).map((p) => substituteKnownPlaceholders(p, paths)),
    ]);
    const domain = domainsById.get(registry.domain || context?.domain);
    const feature = {
      id,
      title: registry.title || context?.title || id,
      domain: registry.domain || context?.domain || null,
      status: registry.status || context?.quick_resume?.current_state || 'unknown',
      src_dir: srcDir,
      src_dir_exists: srcDir ? isDirRel(root, srcDir) : null,
      doc_dir: docDir,
      context_path: existsSync(join(root, contextPath)) ? contextPath : null,
      spec_paths: specs,
      brief_path: existsSync(join(root, docDir, 'BRIEF.md')) ? normalizeRel(join(docDir, 'BRIEF.md')) : null,
      index_path: existsSync(join(root, docDir, 'index.md')) ? normalizeRel(join(docDir, 'index.md')) : null,
      related_files: related,
      db_tables: asArray(context?.references?.db_tables).filter(isNonEmptyString),
      edge_functions: asArray(context?.references?.edge_functions).filter(isNonEmptyString),
      dependencies: context?.references?.dependencies || context?.dependencies || {},
      search_text: featureSearchText({ ...registry, id }, domain, context),
      registered: registryById.has(id),
      docs_exists: folders.includes(id),
    };
    features.push(feature);

    if (feature.context_path) addArtifact(artifacts, makeArtifact({ kind: 'document', path: feature.context_path, featureId: id, source: 'context', exists: true }));
    if (feature.brief_path) addArtifact(artifacts, makeArtifact({ kind: 'document', path: feature.brief_path, featureId: id, source: 'brief', exists: true }));
    if (feature.index_path) addArtifact(artifacts, makeArtifact({ kind: 'document', path: feature.index_path, featureId: id, source: 'feature-index', exists: true }));
    for (const spec of specs) addArtifact(artifacts, makeArtifact({ kind: 'document', path: spec, featureId: id, source: 'spec', exists: true }));
    for (const rel of related) {
      addArtifact(artifacts, makeArtifact({
        kind: classifyArtifactKind(rel),
        path: rel,
        featureId: id,
        source: 'context.related_code',
        exists: existsRel(root, rel),
      }));
    }
    if (srcDir && feature.src_dir_exists) {
      for (const abs of walkFiles(join(root, srcDir), { maxFiles: options.maxFeatureFiles || 1000 })) {
        const rel = normalizeRel(relative(root, abs));
        addArtifact(artifacts, makeArtifact({ kind: classifyArtifactKind(rel), path: rel, featureId: id, source: 'feature.src_dir', exists: true }));
      }
    }
  }

  const pathIndex = buildFeaturePathIndex(features);
  for (const artifact of [
    ...discoverRouteArtifacts(root, paths),
    ...discoverConfiguredArtifacts(root, paths),
  ]) {
    artifact.feature_id = mapArtifactToFeature(artifact, pathIndex);
    addArtifact(artifacts, artifact);
  }

  delete artifacts._seen;

  return {
    schema_version: CODE_OWNERSHIP_INDEX_SCHEMA_VERSION,
    generated_at: options.generatedAt || new Date().toISOString(),
    generator: 'code-ownership-index',
    derived: true,
    project: {
      root,
      project_config_present: projectConfig.present,
      platform: projectConfig.raw?.platform || null,
    },
    source_authorities: {
      project_config: projectConfig.present ? 'project-config.json' : null,
      domain_map: domainMap ? domainMapPath : null,
      docs_features: docsFeaturesPath,
    },
    paths,
    domains,
    features,
    artifacts,
    reverse_lookup: reverseLookup(artifacts),
    warnings,
  };
}

function classifyArtifactKind(relPath) {
  const p = normalizeRel(relPath);
  if (ROUTE_FILE_RE.test(basename(p)) || /(^|\/)(app|pages|routes)\//.test(p)) return 'route';
  if (MIGRATION_FILE_RE.test(p)) return 'migration';
  if (CONTRACT_FILE_RE.test(p)) return 'contract';
  if (SCHEMA_FILE_RE.test(p)) return 'schema';
  if (/\.(md|json)$/.test(p) && p.startsWith('docs/features/')) return 'document';
  return 'source';
}

function tokenize(text) {
  return String(text || '')
    .toLowerCase()
    .split(/[^\p{L}\p{N}_-]+/u)
    .map((s) => s.trim())
    .filter((s) => s.length >= 2);
}

function reasonForToken(feature, token) {
  if (String(feature.id).toLowerCase().includes(token)) return `id:${token}`;
  if (String(feature.title).toLowerCase().includes(token)) return `title:${token}`;
  if (String(feature.domain).toLowerCase().includes(token)) return `domain:${token}`;
  return `text:${token}`;
}

export function queryOwnershipIndex(index, query, options = {}) {
  const tokens = tokenize(query);
  const candidates = [];
  for (const feature of asArray(index?.features)) {
    if (!options.includeArchived && !activeFeature(feature)) continue;
    const searchText = String(feature.search_text || '').toLowerCase();
    let score = 0;
    const reasons = [];
    for (const token of tokens) {
      if (!searchText.includes(token)) continue;
      const weight =
        String(feature.id).toLowerCase().includes(token) ? 6 :
          String(feature.title).toLowerCase().includes(token) ? 5 :
            String(feature.domain).toLowerCase().includes(token) ? 3 :
              1;
      score += weight;
      reasons.push(reasonForToken(feature, token));
    }
    if (score > 0) {
      candidates.push({
        feature_id: feature.id,
        title: feature.title,
        domain: feature.domain,
        status: feature.status,
        score,
        reasons: unique(reasons, 8),
      });
    }
  }
  candidates.sort((a, b) => b.score - a.score || a.feature_id.localeCompare(b.feature_id));
  const limited = candidates.slice(0, options.limit || 5);
  const artifacts = asArray(index?.artifacts);
  const candidateFiles = limited.flatMap((candidate) =>
    artifacts
      .filter((artifact) => artifact.feature_id === candidate.feature_id)
      .map((artifact) => artifact.path),
  );
  return {
    query,
    tokens,
    candidates: limited,
    candidate_files: unique(candidateFiles, options.fileLimit || 30),
    unmapped_artifacts: asArray(index?.artifacts).filter((artifact) => !artifact.feature_id && isAuditedKind(artifact.kind)),
    verdict_hint: verdictHint(limited),
  };
}

function verdictHint(candidates) {
  if (candidates.length === 0) return 'NEW_DOMAIN';
  const [first, second] = candidates;
  if (second && first.score - second.score <= 2) return 'AMBIGUOUS';
  if (first.score >= 12) return 'EXTEND_EXISTING';
  if (first.score >= 4) return 'NEW_IN_EXISTING_DOMAIN';
  return 'AMBIGUOUS';
}

function isAuditedKind(kind) {
  return ['route', 'schema', 'contract', 'migration'].includes(kind);
}

export function auditCodeOwnershipIndex(index) {
  const violations = [];
  const warnings = [...asArray(index?.warnings)];
  const featureById = new Map(asArray(index?.features).map((feature) => [feature.id, feature]));

  if (!index?.source_authorities?.domain_map) {
    violations.push({
      code: VIOLATION_CODES.DOMAIN_MAP_MISSING,
      severity: 'critical',
      detail: 'docs/features/domain-map.json is required for ownership placement.',
    });
  }

  for (const feature of asArray(index?.features)) {
    if (!feature.registered) {
      violations.push({
        code: VIOLATION_CODES.FEATURE_DOC_UNREGISTERED,
        severity: 'major',
        feature_id: feature.id,
        detail: `Feature docs exist but domain-map.json#features[] has no entry for ${feature.id}.`,
      });
    }
    if (feature.registered && activeFeature(feature) && !feature.docs_exists) {
      violations.push({
        code: VIOLATION_CODES.REGISTERED_FEATURE_DOC_MISSING,
        severity: 'major',
        feature_id: feature.id,
        detail: `domain-map.json registers active feature ${feature.id}, but its docs folder is missing.`,
      });
    }
    if (activeFeature(feature) && feature.src_dir && feature.src_dir_exists === false) {
      violations.push({
        code: VIOLATION_CODES.SRC_DIR_MISSING,
        severity: 'major',
        feature_id: feature.id,
        path: feature.src_dir,
        detail: `feature ${feature.id} declares src_dir ${feature.src_dir}, but the directory does not exist.`,
      });
    }
  }

  for (const artifact of asArray(index?.artifacts)) {
    const owner = featureById.get(artifact.feature_id);
    if (
      artifact.source === 'context.related_code'
      && artifact.exists === false
      && !isGlobLike(artifact.path)
      && activeFeature(owner)
    ) {
      violations.push({
        code: VIOLATION_CODES.RELATED_FILE_MISSING,
        severity: 'major',
        feature_id: artifact.feature_id,
        path: artifact.path,
        detail: `CONTEXT.json references ${artifact.path}, but the file does not exist.`,
      });
    }
    if (!artifact.feature_id && isAuditedKind(artifact.kind)) {
      violations.push({
        code: VIOLATION_CODES.UNMAPPED_SOURCE_ARTIFACT,
        severity: 'major',
        path: artifact.path,
        artifact_kind: artifact.kind,
        detail: `${artifact.kind} artifact ${artifact.path} is not mapped to any feature.`,
      });
    }
  }

  return {
    ok: violations.length === 0,
    summary: {
      features: asArray(index?.features).length,
      artifacts: asArray(index?.artifacts).length,
      violations: violations.length,
      warnings: warnings.length,
    },
    violations,
    warnings,
  };
}

export function renderIndexSummary(index) {
  return [
    'Code Ownership Index',
    `  features: ${asArray(index?.features).length}`,
    `  artifacts: ${asArray(index?.artifacts).length}`,
    `  warnings: ${asArray(index?.warnings).length}`,
    `  derived: ${index?.derived === true ? 'yes' : 'no'}`,
  ].join('\n');
}

export function renderQuerySummary(result) {
  const lines = [
    `Query: ${result.query}`,
    `Verdict hint: ${result.verdict_hint}`,
    `Candidates: ${result.candidates.length}`,
  ];
  for (const c of result.candidates) {
    lines.push(`  - ${c.feature_id} (${c.score}) ${c.title}`);
  }
  lines.push(`Candidate files: ${result.candidate_files.length}`);
  if (result.unmapped_artifacts.length > 0) {
    lines.push(`Unmapped audited artifacts: ${result.unmapped_artifacts.length}`);
  }
  return lines.join('\n');
}

export function renderAuditSummary(result) {
  const lines = [
    'Code Ownership Audit',
    `  ok: ${result.ok ? 'yes' : 'no'}`,
    `  features: ${result.summary.features}`,
    `  artifacts: ${result.summary.artifacts}`,
    `  violations: ${result.summary.violations}`,
    `  warnings: ${result.summary.warnings}`,
  ];
  for (const v of result.violations) lines.push(`  - [${v.code}] ${v.detail}`);
  return lines.join('\n');
}
