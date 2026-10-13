# Pluto docs site

The public documentation at <https://iamsonal.github.io/aiAgentStudio/>. It covers only the open-source packages: Pluto Core (`force-app`), Pluto Model Adapters, and Pluto Console.

Built with [Starlight](https://starlight.astro.build). Write for an admin who did not build the feature: short sentences, sentence-case headings, and the labels the admin sees in Setup.

## Run it locally

You need Node.js 22.

```bash
cd docs-starlight
npm ci
npm run dev
```

Open <http://localhost:4321>.

## Where things live

| What             | Where                                                                                                                       |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Pages            | `src/content/docs/`, one Markdown file per page                                                                             |
| Sidebar order    | `astro.config.mjs`                                                                                                          |
| Install links    | `src/data/packages.json`. Put each package's `04t` version Id there when you release.                                       |
| Styles           | `src/styles/custom.css`                                                                                                     |
| Logo and favicon | `src/assets/logo.svg`, `public/favicon.svg`, and `public/favicon.png`. The maintainer regenerates them with `npm run logo`. |

## Generated pages

`npm run dev` and `npm run build` first run `scripts/generate-reference.mjs`. It writes these pages from the metadata, so they never drift from it:

- Object fields, from `force-app/main/default/objects`, for the objects admins set up or read. The list is `adminObjects` in the script. Core's internal objects are left out. Every custom metadata type must be in that list, or the build fails.
- Permission sets, Flow actions, and tool types, from Core, Pluto Model Adapters, and Pluto Console.
- The extension contract, copied from `force-app/contracts/EXTENSIONS.md`.

These files are ignored by git. To change them, change the metadata or the contract. Field pages show each field's **Description**, not its help text.

The same script then checks the hand-written pages. Every field, object, permission set, and Apex class a page names in API form, such as `MaxToolCalls__c` or `AgentKernelOperator`, must still exist. If one was renamed or deleted, the build fails and lists the page and line. Field labels in plain words, such as "Max Tool Calls", are not checked.

To run only the generator and the check:

```bash
npm run generate
```

## Links

Link to other pages from the site root, such as `[Connect a model](/setup/model/)`. The build adds the base path. It fails on a broken link or a missing heading.

## Publish

The `Docs` GitHub Actions workflow builds the site on every pull request and publishes it on every push to `main`. In the repository settings, under **Pages**, set **Source** to **GitHub Actions** once.
