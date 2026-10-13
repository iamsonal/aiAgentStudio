import { defineConfig } from 'astro/config';
import mermaid from 'astro-mermaid';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import remarkBaseLinks from './src/plugins/remark-base-links.mjs';

const repo = 'https://github.com/iamsonal/aiAgentStudio';
const basePath = (process.env.DOCS_BASE_PATH || '/').replace(/(.)\/$/, '$1');

export default defineConfig({
    site: 'https://iamsonal.github.io',
    base: basePath,
    markdown: { remarkPlugins: [remarkBaseLinks({ base: basePath })] },
    // Old page addresses, so links people saved still land somewhere useful.
    redirects: {
        '/getting-started/': '/start/install/',
        '/guides/': '/start/first-agent/',
        '/guides/getting-started/': '/start/install/',
        '/guides/configuration/': '/build/agents/',
        '/guides/developer-guide/': '/extend/',
        '/guides/use-cases/': '/start/first-agent/',
        '/guides/troubleshooting/': '/operate/stuck-run/',
        '/guides/examples/': '/start/first-agent/',
        '/reference/runtime-model/': '/start/how-a-run-works/',
        '/reference/architecture/': '/start/how-a-run-works/',
        '/reference/actions/': '/reference/generated/tool-types/',
        '/reference/security/': '/data/sensitive/',
        '/reference/api-reference/': '/reference/generated/flow-actions/'
    },
    integrations: [
        mermaid({ autoTheme: true, enableLog: false }),
        starlight({
            title: 'Pluto',
            description: 'Run AI agents on standard Salesforce licenses, with any model provider.',
            favicon: '/favicon.svg',
            head: [{ tag: 'link', attrs: { rel: 'icon', href: `${basePath === '/' ? '' : basePath}/favicon.png`, sizes: '32x32' } }],
            logo: { src: './src/assets/logo.svg', alt: 'Pluto' },
            social: [{ icon: 'github', label: 'GitHub', href: repo }],
            editLink: { baseUrl: `${repo}/edit/main/docs-starlight/` },
            lastUpdated: true,
            customCss: ['@fontsource-variable/jetbrains-mono', './src/styles/custom.css'],
            components: { Footer: './src/components/Footer.astro' },
            routeMiddleware: './src/routeData.ts',
            plugins: [starlightLinksValidator()],
            sidebar: [
                {
                    label: 'Start here',
                    items: [
                        { label: 'Overview', link: '/' },
                        { slug: 'start/how-a-run-works' },
                        { slug: 'start/install' },
                        { slug: 'setup/model' },
                        { slug: 'start/first-agent' }
                    ]
                },
                {
                    label: 'Set up',
                    items: [{ slug: 'setup/execution-identity' }, { slug: 'setup/permissions' }, { slug: 'setup/pluto' }]
                },
                {
                    label: 'Build agents',
                    items: [
                        { slug: 'build/agents' },
                        { slug: 'build/tools' },
                        { slug: 'build/query-records' },
                        { slug: 'build/record-tools' },
                        { slug: 'build/run-flow' },
                        { slug: 'build/post-chatter' },
                        { slug: 'build/context' },
                        { slug: 'build/try-tool' }
                    ]
                },
                {
                    label: 'Start runs',
                    items: [{ slug: 'run/start' }, { slug: 'run/conversation' }, { slug: 'run/outside-wait' }, { slug: 'run/chain' }]
                },
                {
                    label: 'Approvals',
                    items: [{ slug: 'approvals/require' }, { slug: 'approvals/decide' }, { slug: 'approvals/policy' }]
                },
                {
                    label: 'Protect data',
                    items: [{ slug: 'data/sensitive' }, { slug: 'data/retention' }]
                },
                {
                    label: 'Run in production',
                    items: [
                        { slug: 'operate/health' },
                        { slug: 'operate/stuck-run' },
                        { slug: 'operate/unknown' },
                        { slug: 'operate/issues' },
                        { slug: 'operate/limits' }
                    ]
                },
                {
                    label: 'Pluto Console',
                    items: [{ slug: 'pluto/editor' }, { slug: 'pluto/run-story' }]
                },
                {
                    label: 'Extend',
                    items: [{ slug: 'extend' }, { slug: 'extend/contract' }]
                },
                {
                    label: 'Reference',
                    items: [
                        { slug: 'reference/generated/tool-types' },
                        { slug: 'reference/generated/flow-actions' },
                        { slug: 'reference/generated/permission-sets' },
                        { slug: 'reference/pause-codes' },
                        { slug: 'reference/generated/objects' },
                        {
                            label: 'Object fields',
                            collapsed: true,
                            items: [{ autogenerate: { directory: 'reference/generated/objects' } }]
                        },
                        { slug: 'reference/license' }
                    ]
                }
            ]
        })
    ]
});
