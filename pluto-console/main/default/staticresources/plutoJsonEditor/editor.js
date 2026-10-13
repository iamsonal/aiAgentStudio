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

(function () {
    var params = new URLSearchParams(window.location.search);
    var channel = params.get('channel');
    var parentOrigin = params.get('parentOrigin');
    var textarea = document.getElementById('editor');
    var applyingValue = false;
    var editor = window.CodeMirror ? window.CodeMirror.fromTextArea(textarea, {
        mode: { name: 'javascript', json: true },
        lineNumbers: false,
        lineWrapping: true,
        indentUnit: 2,
        tabSize: 2,
        matchBrackets: true,
        autoCloseBrackets: true,
        screenReaderLabel: 'JSON configuration',
        // Tab leaves the editor so keyboard users can reach the form actions.
        extraKeys: { Tab: false, 'Shift-Tab': false }
    }) : null;

    function value() {
        return editor ? editor.getValue() : textarea.value;
    }

    function send(type, payload) {
        if (!channel || !parentOrigin) {
            return;
        }
        window.parent.postMessage({ channel: channel, type: type, payload: payload || {} }, parentOrigin);
    }

    function changed() {
        if (!applyingValue) {
            send('change', { value: value() });
        }
    }

    if (editor) {
        editor.on('change', changed);
    } else {
        textarea.addEventListener('input', changed);
    }

    window.addEventListener('message', function (event) {
        if (event.source !== window.parent || event.origin !== parentOrigin || !event.data || event.data.channel !== channel) {
            return;
        }
        var payload = event.data.payload || {};
        if (event.data.type === 'initialize' || event.data.type === 'setValue') {
            if (typeof payload.value === 'string' && payload.value !== value()) {
                applyingValue = true;
                try {
                    if (editor) {
                        editor.setValue(payload.value);
                    } else {
                        textarea.value = payload.value;
                    }
                } finally {
                    applyingValue = false;
                }
            }
        }
        if (event.data.type === 'initialize') {
            var label = typeof payload.label === 'string' ? payload.label : 'JSON configuration';
            textarea.setAttribute('aria-label', label);
            if (editor) {
                editor.setOption('screenReaderLabel', label);
            }
        }
        if (event.data.type === 'initialize' || event.data.type === 'setDisabled') {
            var disabled = payload.disabled === true;
            textarea.readOnly = disabled;
            if (editor) {
                editor.setOption('readOnly', disabled);
            }
        }
        if (event.data.type === 'focus') {
            (editor || textarea).focus();
        }
    });

    send('ready');
})();
