/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { JSDOM } = require('jsdom');

function openEditor() {
    const resource = path.join(__dirname, '../pluto-console/main/default/staticresources/toastUiEditor');
    const dom = new JSDOM(fs.readFileSync(path.join(resource, 'editor.html'), 'utf8'), {
        runScripts: 'outside-only',
        url: 'https://example.test/editor.html?channel=test',
        pretendToBeVisual: true
    });
    const window = dom.window;
    // JSDOM has no layout engine. Toast UI uses these methods to position the caret.
    window.Range.prototype.getBoundingClientRect = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 });
    window.Range.prototype.getClientRects = () => [];
    Object.defineProperty(window.HTMLElement.prototype, 'clientWidth', { get: () => 800 });
    window.eval(fs.readFileSync(path.join(resource, 'toastui-editor.js'), 'utf8'));
    const Editor = window.plutoMarkdownEditor;
    let editor;
    window.plutoMarkdownEditor = function (options) {
        editor = new Editor(options);
        return editor;
    };
    window.eval(window.document.querySelector('script:not([src])').textContent);
    const send = (type, payload) =>
        window.dispatchEvent(new window.MessageEvent('message', { source: window.parent, data: { channel: 'test', type, payload } }));
    return { window, editor, send };
}

test('the toolbar switches modes without losing content and refuses switching when disabled', () => {
    const { window, send } = openEditor();
    try {
        const button = window.document.getElementById('mode-toggle');
        send('setValue', { value: 'Hello **world**' });

        button.focus();
        button.click();
        assert.equal(button.textContent, 'Visual');
        assert.equal(button.getAttribute('aria-label'), 'Switch to Visual');
        assert.equal(window.document.activeElement, button);
        assert.equal(window.document.querySelector('.toastui-editor-md-container .ProseMirror').textContent, 'Hello **world**');

        // A parent update must work while the user is editing Markdown.
        send('setValue', { value: 'Updated **content**' });
        button.click();
        assert.equal(button.textContent, 'Markdown');
        assert.equal(window.document.querySelector('.toastui-editor-ww-container .ProseMirror strong').textContent, 'content');

        send('setDisabled', { disabled: true });
        assert.equal(button.disabled, true);
        button.dispatchEvent(new window.MouseEvent('click'));
        assert.equal(button.textContent, 'Markdown');

        send('setDisabled', { disabled: false });
        button.click();
        assert.equal(button.textContent, 'Visual');
        assert.equal(window.document.querySelector('.toastui-editor-md-container .ProseMirror').textContent, 'Updated **content**');
    } finally {
        window.close();
    }
});

test('the last formatting button inserts emoji at the selection in both modes and refuses disabled fields', () => {
    const { window, editor, send } = openEditor();
    try {
        const toggle = window.document.getElementById('emoji-toggle');
        const picker = window.document.getElementById('emoji-picker');
        const choice = picker.querySelector('[aria-label="Check mark"]');
        const group = toggle.closest('.toastui-editor-toolbar-group');
        const buttons = group.querySelectorAll('button');
        assert.equal(buttons[buttons.length - 1], toggle);
        assert.equal(buttons[buttons.length - 2].classList.contains('link'), true);

        send('setValue', { value: 'Before after' });
        editor.setSelection(8);
        toggle.click();
        assert.equal(picker.hidden, false);
        assert.equal(window.document.activeElement, picker.firstElementChild);
        choice.click();
        assert.equal(editor.getMarkdown(), 'Before ✅after');
        assert.equal(picker.hidden, true);

        window.document.getElementById('mode-toggle').click();
        editor.setSelection([1, 1], [1, 7]);
        toggle.click();
        choice.click();
        assert.equal(editor.getMarkdown(), '✅ ✅after');

        toggle.click();
        window.document.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        assert.equal(picker.hidden, true);
        assert.equal(window.document.activeElement, toggle);

        toggle.click();
        window.document.body.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true }));
        assert.equal(picker.hidden, true);

        toggle.click();
        send('setDisabled', { disabled: true });
        assert.equal(picker.hidden, true);
        assert.equal(toggle.disabled, true);
        toggle.dispatchEvent(new window.MouseEvent('click'));
        choice.dispatchEvent(new window.MouseEvent('click'));
        assert.equal(picker.hidden, true);
        assert.equal(editor.getMarkdown(), '✅ ✅after');

        send('setDisabled', { disabled: false });
        toggle.click();
        assert.equal(picker.hidden, false);
    } finally {
        window.close();
    }
});

test('code blocks preserve multi-line JSON when switching between Visual and Markdown', () => {
    const { window, editor } = openEditor();
    try {
        const source = '{\n  "action": "summarize",\n  "recordId": "example"\n}';
        const codeBlock = window.document.querySelector('.toastui-editor-defaultUI-toolbar button.codeblock');
        codeBlock.click();
        // Simulate typing inside the code block. insertText() creates paragraph nodes.
        const view = editor.getCurrentModeEditor().view;
        view.dispatch(view.state.tr.insertText(source));
        const fenced = '```\n' + source + '\n```';
        assert.equal(editor.getMarkdown(), fenced);

        const mode = window.document.getElementById('mode-toggle');
        mode.click();
        assert.equal(editor.getMarkdown(), fenced);
        mode.click();
        assert.equal(editor.getMarkdown(), fenced);
        assert.equal(window.document.querySelector('.toastui-editor-ww-container pre').textContent, source);

        // The same command can wrap selected multi-line Markdown.
        mode.click();
        editor.setMarkdown('Gather context\nDraft a reply', false);
        editor.setSelection([1, 1], [2, 14]);
        codeBlock.click();
        assert.equal(editor.getMarkdown().trim(), '```\nGather context\nDraft a reply\n```');
    } finally {
        window.close();
    }
});
