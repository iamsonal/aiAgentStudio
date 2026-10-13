import { defineRouteMiddleware } from '@astrojs/starlight/route-data';

// Hero buttons link from the site root, such as /start/install/. Starlight does not add
// the site's base path to them, so add it here, as remark-base-links does for Markdown.
export const onRequest = defineRouteMiddleware((context) => {
  const prefix = import.meta.env.BASE_URL.replace(/\/$/, '');
  context.locals.starlightRoute.entry.data.hero?.actions.forEach((action) => {
    if (/^\/(?!\/)/.test(action.link) && !action.link.startsWith(`${prefix}/`)) action.link = prefix + action.link;
  });
});
