import { defineConfig } from 'astro/config';
import mermaid from 'astro-mermaid';
import starlight from '@astrojs/starlight';

const basePath = process.env.DOCS_BASE_PATH || '/';
const normalizedBasePath = basePath === '/' ? '/' : basePath.replace(/\/$/, '');

export default defineConfig({
  site: 'https://iamsonal.github.io',
  base: normalizedBasePath,
  integrations: [
    mermaid({
      autoTheme: true,
      enableLog: false
    }),
    starlight({
      title: 'Pluto',
      description:
        'Governed AI agent orchestration for Salesforce with runtime control, security, and extensibility built in.',
      favicon: '/favicon.png',
      logo: {
        src: './public/logo.png',
        alt: 'Pluto'
      },
      social: {
        github: 'https://github.com/iamsonal/aiAgentStudio'
      },
      customCss: ['./src/styles/custom.css'],
      sidebar: [
        {
          label: 'Start Here',
          items: [
            { label: 'Overview', link: '/' },
            { label: 'Getting Started', link: '/guides/getting-started/' }
          ]
        },
        {
          label: 'Guides',
          items: [
            { label: 'Guides Overview', link: '/guides/' },
            { label: 'Configuration', link: '/guides/configuration/' },
            { label: 'Developer Guide', link: '/guides/developer-guide/' },
            { label: 'Use Cases', link: '/guides/use-cases/' },
            { label: 'Troubleshooting', link: '/guides/troubleshooting/' }
          ]
        },
        {
          label: 'Reference',
          items: [
            { label: 'Reference Overview', link: '/reference/' },
            { label: 'Runtime Model', link: '/reference/runtime-model/' },
            { label: 'Architecture', link: '/reference/architecture/' },
            { label: 'Standard Actions', link: '/reference/actions/' },
            { label: 'Security', link: '/reference/security/' },
            { label: 'API Reference', link: '/reference/api-reference/' }
          ]
        }
      ]
    })
  ]
});
