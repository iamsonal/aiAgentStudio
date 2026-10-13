// Builds the reference pages from the open-source metadata, so they never drift from it.
// Reads force-app, pluto-console, and pluto-model-adapters. Writes ignored files
// under src/content/docs. Runs before every dev and build.

import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const site = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(site, '..');
const sources = ['force-app', 'pluto-console', 'pluto-model-adapters'].map((p) => join(repo, p, 'main/default'));
const out = join(site, 'src/content/docs/reference/generated');
const github = 'https://github.com/iamsonal/aiAgentStudio/blob/main';

const decode = (s) =>
  s
    .replace(/&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
const tag = (xml, name) => {
  const m = xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`));
  return m ? decode(m[1].trim()) : '';
};
const cell = (s) => (s || '').replace(/\|/g, '\\|').replace(/\s*\n\s*/g, ' ').replace(/</g, '&lt;');
const page = (title, description, body) =>
  `---\ntitle: ${JSON.stringify(title)}\ndescription: ${JSON.stringify(description)}\neditUrl: false\n---\n\n${body.trim()}\n`;
const list = (dir) => (existsSync(dir) ? readdirSync(dir) : []);

rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, 'objects'), { recursive: true });

// Objects: one page per object an admin sets up or reads, fields sorted by label. The rest
// (commands, events, invocations, trust records, signals) are Core's internal state.
// Every custom metadata type is set up by an admin or developer, so each must be listed here.
// Only Core owns objects; Pluto Console ships copies of some object files to set their buttons.
const adminObjects = {
  AgentDefinition__c: 'Set up an agent',
  AgentTool__c: 'Give an agent a tool',
  AgentContextProvider__c: 'Give an agent context',
  AgentExecutionIdentity__c: 'Choose who an agent runs as',
  AgentModel__mdt: 'Connect a model',
  AgentToolType__mdt: 'Register a custom tool class',
  AgentDataPolicy__mdt: 'Change retention',
  AgentRun__c: 'See what a run did',
  AgentApproval__c: 'Decide an approval',
  AgentOperationalIssue__c: 'Handle a failure',
  AgentLifecycleEvent__e: 'Act when a run changes state, in a Flow'
};
const unlisted = sources.flatMap((src) => list(join(src, 'objects')).filter((n) => n.endsWith('__mdt') && !(n in adminObjects)));
if (unlisted.length) {
  throw new Error(`Add each custom metadata type to adminObjects in generate-reference.mjs: ${unlisted.join(', ')}`);
}
const objects = [];
for (const src of sources.slice(0, 1)) {
  for (const name of list(join(src, 'objects')).filter((n) => n in adminObjects)) {
    const metaFile = join(src, 'objects', name, `${name}.object-meta.xml`);
    if (!existsSync(metaFile)) continue;
    const meta = readFileSync(metaFile, 'utf8');
    const label = tag(meta, 'label') || name;
    const fields = list(join(src, 'objects', name, 'fields'))
      .map((f) => {
        const xml = readFileSync(join(src, 'objects', name, 'fields', f), 'utf8');
        const values = [...xml.matchAll(/<value>\s*<fullName>([^<]*)<\/fullName>[\s\S]*?<label>([^<]*)<\/label>/g)].map((m) =>
          decode(m[2])
        );
        return {
          api: basename(f, '.field-meta.xml'),
          label: tag(xml, 'label'),
          type: tag(xml, 'type'),
          description: tag(xml, 'description'),
          values
        };
      })
      .sort((a, b) => a.label.localeCompare(b.label));
    const kind = name.endsWith('__e') ? 'Platform event' : name.endsWith('__mdt') ? 'Custom metadata type' : 'Custom object';
    const description = tag(meta, 'description');
    const rows = fields.map(
      (f) =>
        `| ${cell(f.label)} | \`${f.api}\` | ${cell(f.type)} | ${cell(f.description)}${f.values.length ? ` Values: ${cell(f.values.join(', '))}.` : ''} |`
    );
    const slug = name.replace(/__(c|e|mdt)$/, '').replace(/([a-z])([A-Z])/g, '$1-$2').toLowerCase();
    objects.push({ name, label, kind, slug, description, use: adminObjects[name] });
    writeFileSync(
      join(out, 'objects', `${slug}.md`),
      page(
        label,
        `Fields of ${label} (${name}).`,
        `${kind} \`${name}\`.${description ? ` ${cell(description)}` : ''}\n\n` +
          (rows.length
            ? `| Field | API name | Type | Description |\n| --- | --- | --- | --- |\n${rows.join('\n')}\n`
            : 'This object has no custom fields.\n')
      )
    );
  }
}

// Permission sets.
const permissionSets = [];
for (const src of sources) {
  for (const f of list(join(src, 'permissionsets'))) {
    const xml = readFileSync(join(src, 'permissionsets', f), 'utf8');
    permissionSets.push({ api: basename(f, '.permissionset-meta.xml'), label: tag(xml, 'label'), description: tag(xml, 'description') });
  }
}
permissionSets.sort((a, b) => a.label.localeCompare(b.label));
writeFileSync(
  join(out, 'permission-sets.md'),
  page(
    'Permission sets',
    'Every permission set Core, Pluto Console, and Pluto Model Adapters ship.',
    `To decide who gets each permission set, see [Give people access](/setup/permissions/).\n\n| Permission set | API name | What it grants |\n| --- | --- | --- |\n` +
      permissionSets.map((p) => `| ${cell(p.label)} | \`${p.api}\` | ${cell(p.description)} |`).join('\n')
  )
);

// Flow actions: every @InvocableMethod, with its inputs and outputs.
const classFiles = sources.flatMap((src) => {
  const walk = (dir) =>
    list(dir).flatMap((f) => {
      const p = join(dir, f);
      if (f.endsWith('.cls') && !/Test\.cls$/.test(f)) return [p];
      return f.includes('.') ? [] : walk(p);
    });
  return walk(join(src, 'classes'));
});
const attr = (text, name) => {
  const m = text.match(new RegExp(`${name}\\s*=\\s*'((?:\\\\'|[^'])*)'`, 'i'));
  return m ? m[1].replace(/\\'/g, "'") : '';
};
const variables = (source, className) => {
  if (!className) return [];
  const start = source.search(new RegExp(`class\\s+${className}\\b`));
  if (start < 0) return [];
  let depth = 0;
  let end = source.indexOf('{', start);
  for (let i = end; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) {
      end = i;
      break;
    }
  }
  const body = source.slice(start, end);
  return [...body.matchAll(/@InvocableVariable\s*(\(([^)]*)\))?\s*(?:global|public)\s+([\w<>.,\s]+?)\s+(\w+)\s*[;{=]/g)].map((m) => ({
    name: m[4],
    label: attr(m[2] || '', 'label') || m[4],
    description: attr(m[2] || '', 'description'),
    required: /required\s*=\s*true/i.test(m[2] || ''),
    type: m[3].trim()
  }));
};
const actions = [];
for (const file of classFiles) {
  const source = readFileSync(file, 'utf8');
  for (const m of source.matchAll(/@InvocableMethod\s*\(([\s\S]*?)\)\s*(?:global|public)\s+static\s+(?:List<(\w+)>|void)\s+\w+\s*\(\s*List<(\w+)>/g)) {
    actions.push({
      label: attr(m[1], 'label'),
      description: attr(m[1], 'description'),
      className: basename(file, '.cls'),
      inputs: variables(source, m[3]),
      outputs: variables(source, m[2])
    });
  }
}
actions.sort((a, b) => a.label.localeCompare(b.label));
const varTable = (vars, withRequired) =>
  vars.length
    ? (withRequired ? '| Name | Required | Description |\n| --- | --- | --- |\n' : '| Name | Description |\n| --- | --- |\n') +
      vars
        .map((v) => (withRequired ? `| ${cell(v.label)} | ${v.required ? 'Yes' : 'No'} | ${cell(v.description)} |` : `| ${cell(v.label)} | ${cell(v.description)} |`))
        .join('\n')
    : 'None.';
writeFileSync(
  join(out, 'flow-actions.md'),
  page(
    'Flow actions',
    'Every Flow action Core and Pluto Console ship, with inputs and outputs.',
    `Find these in Flow Builder under **Action**. Each one checks the user's permissions itself.\n\n` +
      actions
        .map(
          (a) =>
            `## ${a.label}\n\n${cell(a.description)}\n\nApex class: \`${a.className}\`.\n\n### Inputs\n\n${varTable(a.inputs, true)}\n\n### Outputs\n\n${varTable(a.outputs, false)}\n`
        )
        .join('\n')
  )
);

// Tool types.
const effects = { InOrg: 'Stays in This Org', ReadsOutside: 'Reads Outside Systems', ChangesOutside: 'Changes Outside Systems' };
const toolTypes = [];
for (const src of sources) {
  for (const f of list(join(src, 'customMetadata')).filter((f) => f.startsWith('AgentToolType.'))) {
    const xml = readFileSync(join(src, 'customMetadata', f), 'utf8');
    const value = (field) => {
      const m = xml.match(new RegExp(`<field>${field}</field>\\s*<value[^>]*>([^<]*)</value>`));
      return m ? decode(m[1]) : '';
    };
    toolTypes.push({
      name: f.replace(/^AgentToolType\./, '').replace(/\.md-meta\.xml$/, ''),
      label: tag(xml, 'label'),
      description: value('Description__c'),
      effects: effects[value('Effects__c')] || value('Effects__c'),
      className: value('ToolClass__c')
    });
  }
}
writeFileSync(
  join(out, 'tool-types.md'),
  page(
    'Tool types',
    'The tool types Core ships.',
    `Enter the name in the **Tool Type** field of an Agent Tool. [Effects](/build/tools/#effects) decides what Core does when a call fails.\n\n| Tool type | Name | Effects | What it does |\n| --- | --- | --- | --- |\n` +
      toolTypes.map((t) => `| ${cell(t.label)} | \`${t.name}\` | ${t.effects} | ${cell(t.description)} |`).join('\n')
  )
);

// Objects index.
objects.sort((a, b) => a.label.localeCompare(b.label));
writeFileSync(
  join(out, 'objects.md'),
  page(
    'Objects',
    'The Pluto Core objects admins set up or read.',
    `These are the objects you set up or read. Core also keeps internal records for each run's steps and protected values. Never change those by hand.\n\nField descriptions on these pages come from the object metadata, and are rebuilt on every build.\n\n| Object | Use it to | API name |\n| --- | --- | --- |\n` +
      objects.map((o) => `| [${cell(o.label)}](/reference/generated/objects/${o.slug}/) | ${o.use} | \`${o.name}\` |`).join('\n')
  )
);

// The extension contract, copied with its links pointed at GitHub.
const contract = readFileSync(join(repo, 'force-app/contracts/EXTENSIONS.md'), 'utf8')
  .replace(/^# .*\n/, '')
  .replace(/\]\(\.\.\/README\.md(#[^)]*)?\)/g, (_, hash) => `](${github}/force-app/README.md${hash || ''})`);
writeFileSync(
  join(site, 'src/content/docs/extend/contract.md'),
  page(
    'Extension contract',
    'The rules every tool, model provider, context provider, and policy class must follow.',
    `This page is copied from [force-app/contracts/EXTENSIONS.md](${github}/force-app/contracts/EXTENSIONS.md) on every build. Edit that file, not this page.\n\n${contract}`
  ).replace('editUrl: false', `editUrl: ${JSON.stringify(`https://github.com/iamsonal/aiAgentStudio/edit/main/force-app/contracts/EXTENSIONS.md`)}`)
);

// Hand-written pages: every object, field, permission set, and AgentKernel class they name must still exist.
// A renamed or deleted one fails the build, so the page is fixed in the same change.
const known = new Set([...permissionSets.map((p) => p.api), ...classFiles.map((f) => basename(f, '.cls'))]);
for (const src of sources) {
  for (const name of list(join(src, 'objects'))) {
    known.add(name);
    for (const f of list(join(src, 'objects', name, 'fields'))) known.add(basename(f, '.field-meta.xml'));
  }
}
const docsRoot = join(site, 'src/content/docs');
const pages = (dir) =>
  list(dir).flatMap((f) => {
    const p = join(dir, f);
    if (f === 'generated' || f === 'contract.md') return [];
    return /\.mdx?$/.test(f) ? [p] : f.includes('.') ? [] : pages(p);
  });
const stale = [];
for (const file of pages(docsRoot)) {
  readFileSync(file, 'utf8')
    .split('\n')
    .forEach((line, i) => {
      for (const m of line.matchAll(/\b(?:\w+\.)?(\w+__(?:c|mdt|e))\b|`(AgentKernel\w+|AgentModelAdapters|PlutoAdmin)`/g)) {
        const name = m[1] || m[2];
        if (!known.has(name)) stale.push(`${file.slice(site.length + 1)}:${i + 1}: ${name}`);
      }
    });
}
if (stale.length) {
  console.error(`These pages name metadata that no longer exists. Update them:\n${stale.join('\n')}`);
  process.exit(1);
}

console.log(`Reference: ${objects.length} objects, ${permissionSets.length} permission sets, ${actions.length} Flow actions, ${toolTypes.length} tool types.`);
