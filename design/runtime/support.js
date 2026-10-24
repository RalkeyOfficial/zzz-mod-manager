// Runtime for the .dc.html boards: fills {{holes}}, repeats <sc-for>, branches <sc-if>, runs the
// board's Component class and shows its tweaks. The format is described in design/README.md.
(() => {
  'use strict';

  const hide = document.createElement('style');
  hide.textContent = 'x-dc{display:none!important}';
  document.head.appendChild(hide);

  class DCLogic {
    constructor(props) {
      this.props = props;
      this.state = {};
    }
    setState(update, done) {
      const next = typeof update === 'function' ? update(this.state, this.props) : update;
      this.state = { ...this.state, ...next };
      this.__schedule(done);
    }
    forceUpdate(done) {
      this.__schedule(done);
    }
    __schedule() {}
  }
  window.DCLogic = DCLogic;

  const HOLE = /\{\{([^}]*)\}\}/g;
  const wholeHole = (s) => {
    const m = /^\s*\{\{([^}]*)\}\}\s*$/.exec(s);
    return m ? m[1] : null;
  };

  function lookup(path, scope) {
    path = path.trim();
    if (path === 'true') return true;
    if (path === 'false') return false;
    if (path === 'null') return null;
    if (/^-?\d+(\.\d+)?$/.test(path)) return Number(path);
    if (/^(['"]).*\1$/.test(path)) return path.slice(1, -1);
    let v = scope;
    for (const part of path.split('.')) {
      if (v == null) return undefined;
      v = v[part];
    }
    return v;
  }

  const textOf = (v) => (v == null || typeof v === 'boolean' ? '' : String(v));
  const fill = (s, scope) => s.replace(HOLE, (_, p) => textOf(lookup(p, scope)));

  // Each element keeps its handlers in __on, so a re-render can swap them without rebinding.
  function listen(el, on) {
    el.__on = on;
    el.__bound = el.__bound || new Set();
    for (const type of Object.keys(on)) {
      if (el.__bound.has(type)) continue;
      el.__bound.add(type);
      el.addEventListener(type, (e) => {
        const fn = el.__on && el.__on[type];
        if (typeof fn === 'function') fn(e);
      });
    }
  }

  function build(node, scope, out) {
    if (node.nodeType === Node.TEXT_NODE) {
      out.push(document.createTextNode(fill(node.nodeValue, scope)));
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const kind = node.localName === 'template' && node.getAttribute('data-sc');
    if (kind) {
      const kids = (node.content || node).childNodes;
      if (kind === 'for') {
        const list = lookup(wholeHole(node.getAttribute('list')) || '', scope) || [];
        const as = node.getAttribute('as');
        Array.from(list).forEach((item, i) => {
          const inner = Object.create(scope);
          inner[as] = item;
          inner.$index = i;
          for (const k of kids) build(k, inner, out);
        });
      } else {
        const raw = node.getAttribute('value') || '';
        const hole = wholeHole(raw);
        if (hole != null ? lookup(hole, scope) : fill(raw, scope)) for (const k of kids) build(k, scope, out);
      }
      return;
    }

    const el = document.createElementNS(node.namespaceURI, node.localName);
    const on = {};
    for (const { name, value } of Array.from(node.attributes)) {
      if (name.startsWith('hint-')) continue;
      const hole = wholeHole(value);
      if (name.length > 2 && name.startsWith('on') && hole != null) {
        on[name.slice(2)] = lookup(hole, scope);
        continue;
      }
      if (hole != null) {
        const v = lookup(hole, scope);
        if (v == null || v === false || typeof v === 'function' || typeof v === 'object') continue;
        el.setAttribute(name, v === true ? '' : String(v));
      } else {
        el.setAttribute(name, value.includes('{{') ? fill(value, scope) : value);
      }
    }
    listen(el, on);
    const kids = [];
    for (const k of (node.content || node).childNodes) build(k, scope, kids);
    for (const k of kids) el.appendChild(k);
    out.push(el);
  }

  const sameKind = (a, b) =>
    a.nodeType === b.nodeType &&
    (a.nodeType !== Node.ELEMENT_NODE || (a.namespaceURI === b.namespaceURI && a.localName === b.localName));

  // Updates the live tree in place, so focus, caret, hover and CSS transitions survive a state change.
  function morphChildren(parent, nodes) {
    const old = Array.from(parent.childNodes);
    nodes.forEach((n, i) => {
      const o = old[i];
      if (!o) parent.appendChild(n);
      else if (!sameKind(o, n)) parent.replaceChild(n, o);
      else morph(o, n);
    });
    for (let i = nodes.length; i < old.length; i++) old[i].remove();
  }

  function morph(o, n) {
    if (o.nodeType !== Node.ELEMENT_NODE) {
      if (o.nodeValue !== n.nodeValue) o.nodeValue = n.nodeValue;
      return;
    }
    for (const a of Array.from(o.attributes)) if (!n.hasAttribute(a.name)) o.removeAttribute(a.name);
    for (const a of Array.from(n.attributes)) if (o.getAttribute(a.name) !== a.value) o.setAttribute(a.name, a.value);
    if (o.localName === 'input' && n.hasAttribute('value') && o.value !== n.getAttribute('value')) {
      o.value = n.getAttribute('value');
    }
    listen(o, n.__on || {});
    morphChildren(o, Array.from(n.childNodes));
  }

  function readProps(script) {
    let defs = {};
    try {
      defs = JSON.parse(script.getAttribute('data-props') || '{}');
    } catch (e) {
      console.error('data-props is not valid JSON', e);
    }
    const params = new URLSearchParams(location.search);
    const props = {};
    for (const [key, def] of Object.entries(defs)) {
      if (key.startsWith('$') || !def || typeof def !== 'object') continue;
      props[key] = def.default;
      if (!params.has(key)) continue;
      const raw = params.get(key);
      if (def.editor === 'int' || def.editor === 'float' || def.editor === 'range') props[key] = Number(raw);
      else if (def.editor === 'boolean') props[key] = raw === 'true';
      else props[key] = raw;
    }
    return { defs, props };
  }

  function showError(root, err) {
    console.error(err);
    root.innerHTML = '';
    const box = document.createElement('pre');
    box.style.cssText = 'margin:24px;padding:16px;border-radius:8px;background:#3A1512;color:#FF9A8E;font:12px/1.5 monospace;white-space:pre-wrap';
    box.textContent = String(err && err.stack ? err.stack : err);
    root.appendChild(box);
  }

  async function boot() {
    const host = document.querySelector('x-dc');
    const script = document.querySelector('script[data-dc-script]');
    if (!host || !script) return;

    // The file is re-read as text because the page's own parse moves loops out of <table> rows.
    const src = await (await fetch(location.href, { cache: 'no-store' })).text();
    const body = src.slice(src.indexOf('<x-dc>') + 6, src.lastIndexOf('</x-dc>'));
    const tpl = document.createElement('template');
    tpl.innerHTML = body.replace(/<(\/?)sc-(for|if)\b/g, (_, close, kind) =>
      close ? '</template' : `<template data-sc="${kind}"`
    );
    // The page's own <helmet> stays in the hidden <x-dc>: its stylesheets apply from there, and moving
    // them would make the browser load the fonts a second time.
    const helmet = tpl.content.querySelector('helmet');
    if (helmet) helmet.remove();
    for (const n of Array.from(host.childNodes)) if (n.localName !== 'helmet') n.remove();

    const root = document.createElement('div');
    root.setAttribute('data-dc-root', '');
    host.after(root);

    const { defs, props } = readProps(script);
    let Component;
    let comp;
    try {
      Component = new Function('DCLogic', `${script.textContent}\nreturn Component;`)(DCLogic);
      comp = new Component({ ...props });
    } catch (err) {
      showError(root, err);
      return;
    }

    let mounted = false;
    let queued = false;
    const waiting = [];
    const render = () => {
      queued = false;
      const prevProps = comp.__prevProps;
      const prevState = comp.__prevState;
      try {
        const vals = comp.renderVals() || {};
        const nodes = [];
        for (const k of tpl.content.childNodes) build(k, vals, nodes);
        morphChildren(root, nodes);
      } catch (err) {
        showError(root, err);
        return;
      }
      comp.__prevProps = comp.props;
      comp.__prevState = comp.state;
      if (!mounted) {
        mounted = true;
        if (comp.componentDidMount) comp.componentDidMount();
      } else if (comp.componentDidUpdate) {
        comp.componentDidUpdate(prevProps, prevState);
      }
      waiting.splice(0).forEach((fn) => fn());
    };
    comp.__schedule = (done) => {
      if (typeof done === 'function') waiting.push(done);
      if (queued) return;
      queued = true;
      queueMicrotask(render);
    };
    render();

    const params = new URLSearchParams(location.search);
    if (params.get('embed') !== '1') tweaks(defs, comp, render);
  }

  // A small panel for the props declared with an editor, kept in a shadow root so board CSS can't reach it.
  function tweaks(defs, comp, render) {
    const keys = Object.keys(defs).filter((k) => !k.startsWith('$') && defs[k] && defs[k].editor);
    if (!keys.length) return;
    const host = document.createElement('div');
    host.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647';
    document.body.appendChild(host);
    const shadow = host.attachShadow({ mode: 'open' });
    shadow.innerHTML = `<style>
      :host{all:initial;font:12px/1.4 system-ui,sans-serif;color:#ECEDEE}
      button,select,input{font:inherit;color:inherit}
      .toggle{height:30px;padding:0 12px;border-radius:999px;border:1px solid #3A3E46;background:#1A1C20;cursor:pointer}
      .panel{position:absolute;right:0;bottom:38px;width:240px;display:none;flex-direction:column;gap:12px;padding:14px;border-radius:12px;border:1px solid #3A3E46;background:#121316;box-shadow:0 16px 40px rgba(0,0,0,.5)}
      .panel.open{display:flex}
      label{display:flex;flex-direction:column;gap:6px;color:#A9ADB5}
      .row{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
      .sw{width:22px;height:22px;border-radius:6px;border:1px solid #3A3E46;cursor:pointer;padding:0}
      .sw.on{outline:2px solid #ECEDEE;outline-offset:1px}
      select,input[type=text],input[type=number]{height:28px;padding:0 8px;border-radius:7px;border:1px solid #3A3E46;background:#1A1C20}
      input[type=color]{width:28px;height:24px;padding:0;border:0;background:none;cursor:pointer}
    </style><div class="panel"></div><button class="toggle" type="button">Tweaks</button>`;
    const panel = shadow.querySelector('.panel');
    shadow.querySelector('.toggle').addEventListener('click', () => panel.classList.toggle('open'));

    const set = (key, value) => {
      comp.props = { ...comp.props, [key]: value };
      const params = new URLSearchParams(location.search);
      if (value === defs[key].default) params.delete(key);
      else params.set(key, String(value));
      const q = params.toString();
      history.replaceState(null, '', q ? `?${q}` : location.pathname);
      draw();
      render();
    };

    const draw = () => {
      panel.innerHTML = '';
      for (const key of keys) {
        const def = defs[key];
        const value = comp.props[key];
        const label = document.createElement('label');
        label.textContent = key;
        const row = document.createElement('div');
        row.className = 'row';
        if (def.editor === 'color') {
          for (const opt of def.options || []) {
            const sw = document.createElement('button');
            sw.type = 'button';
            sw.className = String(opt).toLowerCase() === String(value).toLowerCase() ? 'sw on' : 'sw';
            sw.style.background = opt;
            sw.title = opt;
            sw.addEventListener('click', () => set(key, opt));
            row.appendChild(sw);
          }
          const pick = document.createElement('input');
          pick.type = 'color';
          pick.value = /^#[0-9a-f]{6}$/i.test(value) ? value : '#000000';
          pick.addEventListener('change', () => set(key, pick.value.toUpperCase()));
          row.appendChild(pick);
        } else if (def.editor === 'enum') {
          const sel = document.createElement('select');
          for (const opt of def.options || []) sel.add(new Option(opt, opt, false, opt === value));
          sel.addEventListener('change', () => set(key, sel.value));
          row.appendChild(sel);
        } else if (def.editor === 'boolean') {
          const box = document.createElement('input');
          box.type = 'checkbox';
          box.checked = !!value;
          box.addEventListener('change', () => set(key, box.checked));
          row.appendChild(box);
        } else {
          const numeric = def.editor === 'int' || def.editor === 'float' || def.editor === 'range';
          const field = document.createElement('input');
          field.type = numeric ? 'number' : 'text';
          field.value = value ?? '';
          field.addEventListener('change', () => set(key, numeric ? Number(field.value) : field.value));
          row.appendChild(field);
        }
        label.appendChild(row);
        panel.appendChild(label);
      }
    };
    draw();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
