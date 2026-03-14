import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import micromark from '@salesforce/resourceUrl/micromark';

/**
 * Generic markdown viewer component that renders markdown text to HTML.
 *
 * @example
 * <c-markdown-viewer value={markdownText}></c-markdown-viewer>
 *
 * @example With event handling
 * <c-markdown-viewer
 *     value={markdownText}
 *     onrenderingcomplete={handleRendered}
 *     onerror={handleError}>
 * </c-markdown-viewer>
 *
 * @example Hide loading skeleton
 * <c-markdown-viewer value={markdownText} hide-loading></c-markdown-viewer>
 */
export default class MarkdownViewer extends LightningElement {
    _value = '';
    _renderedHtml = '';
    _isReady = false;
    _libraryLoaded = false;
    _libraryLoading = false;
    _hasError = false;
    _errorMessage = '';

    /**
     * The markdown text to render
     * @type {string}
     */
    @api
    get value() {
        return this._value;
    }

    set value(val) {
        const newValue = val || '';
        if (this._value === newValue) return;

        this._value = newValue;
        this._isReady = false;

        if (this._libraryLoaded) {
            this._renderMarkdown();
        }
    }

    /**
     * Hide the loading skeleton (useful when parent handles loading state)
     * @type {boolean}
     */
    @api hideLoading = false;
    @api compactMode = false;

    /**
     * Returns true if the component is currently loading
     * @type {boolean}
     */
    @api
    get loading() {
        return this._libraryLoading || (this._value && !this._isReady);
    }

    /**
     * Returns true if there was an error
     * @type {boolean}
     */
    @api
    get hasError() {
        return this._hasError;
    }

    /**
     * Returns the rendered HTML (for parent components that need it)
     * @type {string}
     */
    @api
    get html() {
        return this._renderedHtml;
    }

    /**
     * Force re-render the markdown
     */
    @api
    refresh() {
        if (this._libraryLoaded) {
            this._isReady = false;
            this._renderMarkdown();
        }
    }

    async connectedCallback() {
        if (!this._libraryLoaded && !this._libraryLoading) {
            await this._loadLibrary();
        }
    }

    async _loadLibrary() {
        if (this._libraryLoading || this._libraryLoaded) return;

        this._libraryLoading = true;

        try {
            await Promise.all([loadScript(this, micromark + '/js/micromark-umd.js'), loadScript(this, micromark + '/js/micromark-extension-gfm-umd.js')]);

            this._libraryLoaded = !!(window.micromark && window.micromark_gfm);

            if (this._libraryLoaded && this._value) {
                this._renderMarkdown();
            } else if (!this._value) {
                this._isReady = true;
            }
        } catch (error) {
            console.error('[MarkdownViewer] Failed to load library:', error);
            this._hasError = true;
            this._errorMessage = 'Failed to load markdown renderer';

            // Use fallback rendering
            if (this._value) {
                this._renderedHtml = this._basicMarkdownToHtml(this._value);
                this._isReady = true;
            }

            this.dispatchEvent(
                new CustomEvent('error', {
                    detail: { message: this._errorMessage, error }
                })
            );
        } finally {
            this._libraryLoading = false;
        }
    }

    _renderMarkdown() {
        if (!this._value) {
            this._renderedHtml = '';
            this._isReady = true;
            return;
        }

        try {
            if (window.micromark?.micromark) {
                const options = { allowDangerousHtml: true };

                if (window.micromark_gfm?.gfm) {
                    options.extensions = [window.micromark_gfm.gfm()];
                    options.htmlExtensions = [window.micromark_gfm.gfmHtml()];
                }

                this._renderedHtml = window.micromark.micromark(this._value, options);
            } else {
                this._renderedHtml = this._basicMarkdownToHtml(this._value);
            }

            if (this.compactMode) {
                this._renderedHtml = this._applyCompactFormatting(this._renderedHtml);
            }

            this._isReady = true;
            this.dispatchEvent(
                new CustomEvent('renderingcomplete', {
                    detail: { html: this._renderedHtml }
                })
            );
        } catch (error) {
            console.error('[MarkdownViewer] Render error:', error);
            this._renderedHtml = this._basicMarkdownToHtml(this._value);
            this._isReady = true;

            this.dispatchEvent(
                new CustomEvent('renderingcomplete', {
                    detail: { html: this._renderedHtml, fallback: true }
                })
            );
        }
    }

    _basicMarkdownToHtml(text) {
        return text
            .replace(/^### (.*$)/gim, '<h3>$1</h3>')
            .replace(/^## (.*$)/gim, '<h2>$1</h2>')
            .replace(/^# (.*$)/gim, '<h1>$1</h1>')
            .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
            .replace(/\*(.*?)\*/g, '<em>$1</em>')
            .replace(/`(.*?)`/g, '<code>$1</code>')
            .replace(/^\- (.*$)/gim, '<li>$1</li>')
            .replace(/^\d+\. (.*$)/gim, '<li>$1</li>')
            .replace(/\n\n/g, '</p><p>')
            .replace(/\n/g, '<br>');
    }

    _applyCompactFormatting(html) {
        if (!html) {
            return html;
        }

        return html.replace(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi, (_match, _level, content) => `<p><strong>${content}</strong></p>`);
    }

    get showLoading() {
        return !this.hideLoading && (this._libraryLoading || (this._value && !this._isReady));
    }

    get showContent() {
        return this._isReady && this._renderedHtml && !this._hasError;
    }

    get showError() {
        return this._hasError && !this._libraryLoading;
    }

    get showEmpty() {
        return this._isReady && !this._renderedHtml && !this._hasError;
    }

    get errorMessage() {
        return this._errorMessage;
    }

    get renderedHtml() {
        return this._renderedHtml;
    }

    get contentClass() {
        return this.compactMode ? 'markdown-content markdown-content-compact' : 'markdown-content';
    }
}
