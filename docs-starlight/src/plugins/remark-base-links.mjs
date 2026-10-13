// Pages link to each other from the site root, such as /setup/model/. This adds the
// site's base path, so the same Markdown works at / and at /aiAgentStudio/.
export default function remarkBaseLinks({ base }) {
  const prefix = base === '/' ? '' : base.replace(/\/$/, '');
  const visit = (node) => {
    if ((node.type === 'link' || node.type === 'definition') && /^\/(?!\/)/.test(node.url) && !node.url.startsWith(`${prefix}/`)) {
      node.url = prefix + node.url;
    }
    node.children?.forEach(visit);
  };
  return () => (tree) => visit(tree);
}
