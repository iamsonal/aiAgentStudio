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

import { LightningElement, api } from 'lwc';

/**
 * Array Value Editor Component
 * Provides an intuitive UI for editing array values with add/remove item functionality
 */
export default class ArrayValueEditor extends LightningElement {
    @api label = 'Array Values';
    @api helpText = 'Add or remove items from the array.';
    @api disabled = false;
    @api itemType = 'string'; // string, number, boolean, object
    @api showJsonPreview = false;
    @api value = '[]'; // The current JSON array value from parent
    @api availableFields = []; // Field options for smart-lookup (passed from parent when SObject is selected)
    @api allowedValues = [];

    // ===== PUBLIC API - No longer needed as we use @api value =====

    // ===== COMPUTED PROPERTIES =====

    get items() {
        // Parse the value prop to get items for display
        if (this.value === null || this.value === undefined) {
            return [];
        }
        const rawValue = typeof this.value === 'string' ? this.value : JSON.stringify(this.value);
        if (rawValue.trim() === '' || rawValue === '[]') {
            return [];
        }

        try {
            const parsedArray = JSON.parse(rawValue);
            if (!Array.isArray(parsedArray)) {
                return [];
            }

            return parsedArray.map((val, index) => {
                const item = {
                    id: index,
                    displayIndex: index + 1,
                    value: this.itemType === 'object' ? JSON.stringify(val, null, 2) : String(val),
                    booleanValue: this.itemType === 'boolean' ? val === true || val === 'true' : false
                };

                // For objects, create key-value pairs for the editor
                if (this.itemType === 'object' && typeof val === 'object' && val !== null) {
                    item.keyValuePairs = Object.keys(val).map((key, pairIndex) => {
                        // Convert placeholder keys back to empty strings for editing
                        const displayKey = key.startsWith('__placeholder_') ? '' : key;
                        const propValue = val[key];

                        // Infer type from value
                        let valueType = 'string';
                        if (typeof propValue === 'boolean') {
                            valueType = 'boolean';
                        } else if (typeof propValue === 'number') {
                            valueType = 'number';
                        }

                        const pair = {
                            id: `${index}-${pairIndex}`,
                            key: displayKey,
                            value: String(propValue),
                            valueType: valueType,
                            booleanValue: propValue === true || propValue === 'true',
                            inputType: valueType === 'number' ? 'number' : 'text',
                            isBooleanValue: valueType === 'boolean'
                        };

                        return pair;
                    });
                    this.applyKeyValidation(item);
                } else if (this.itemType === 'object') {
                    item.keyValuePairs = [];
                }

                return item;
            });
        } catch (error) {
            console.error('Error parsing array JSON:', error);
            return [];
        }
    }

    get hasItems() {
        return this.items && this.items.length > 0;
    }

    get isStringType() {
        return this.itemType === 'string';
    }

    get isNumberType() {
        return this.itemType === 'number' || this.itemType === 'integer';
    }

    get isBooleanType() {
        return this.itemType === 'boolean';
    }

    get isObjectType() {
        return this.itemType === 'object';
    }

    get hasFieldOptions() {
        return Array.isArray(this.availableFields) && this.availableFields.length > 0;
    }

    get hasAllowedValues() {
        return Array.isArray(this.allowedValues) && this.allowedValues.length > 0;
    }

    get allowedValueOptions() {
        return this.allowedValues.map((value) => ({ label: value, value }));
    }

    buildJsonValue(items) {
        // Build JSON string from items array
        if (!items || items.length === 0) {
            return '[]';
        }

        const values = items.map((item) => {
            if (this.isBooleanType) {
                return item.booleanValue;
            } else if (this.isNumberType) {
                const numValue = item.value === '' ? null : parseFloat(item.value);
                return isNaN(numValue) ? null : numValue;
            } else if (this.isObjectType) {
                // Build object from key-value pairs
                if (item.keyValuePairs && item.keyValuePairs.length > 0) {
                    const obj = {};
                    const seenKeys = new Set();
                    item.keyValuePairs.forEach((pair, pairIndex) => {
                        const trimmedKey = pair.key ? pair.key.trim() : '';
                        if (!trimmedKey || seenKeys.has(trimmedKey)) {
                            return;
                        }
                        seenKeys.add(trimmedKey);

                        // Convert value based on type
                        let convertedValue;
                        if (pair.valueType === 'boolean') {
                            convertedValue = pair.booleanValue === true || pair.booleanValue === 'true';
                        } else if (pair.valueType === 'number') {
                            const numValue = pair.value === '' ? null : parseFloat(pair.value);
                            convertedValue = isNaN(numValue) ? null : numValue;
                        } else {
                            convertedValue = pair.value || '';
                        }

                        obj[trimmedKey] = convertedValue;
                    });
                    return obj;
                }
                if (!item.keyValuePairs) {
                    // Fallback to parsing JSON if no key-value pairs
                    try {
                        return JSON.parse(item.value);
                    } catch (e) {
                        return {};
                    }
                }
                // Pairs were explicitly emptied (e.g. the last pair was removed):
                // the item is now an empty object, not its stale JSON value.
                return {};
            } else {
                // String type
                return item.value || '';
            }
        });

        return JSON.stringify(values);
    }

    get jsonPreview() {
        try {
            const parsed = JSON.parse(this.value || '[]');
            return JSON.stringify(parsed, null, 2);
        } catch (e) {
            return this.value || '[]';
        }
    }

    get propertyValueTypeOptions() {
        return [
            { label: 'String', value: 'string' },
            { label: 'Number', value: 'number' },
            { label: 'Boolean', value: 'boolean' }
        ];
    }

    // ===== EVENT HANDLERS =====

    handleAddItem() {
        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        // Ids must stay unique for for:each keys: derive from max, never length,
        // so remove+add cannot collide with a surviving item.
        const newId = currentItems.reduce((max, item) => (typeof item.id === 'number' && item.id > max ? item.id : max), -1) + 1;
        const newItem = {
            id: newId,
            displayIndex: currentItems.length + 1,
            value: this.getDefaultValue(),
            booleanValue: false
        };

        // For objects, initialize with one empty key-value pair to get started
        if (this.isObjectType) {
            newItem.keyValuePairs = [
                {
                    id: `${newId}-0`,
                    key: '',
                    value: '',
                    valueType: 'string',
                    booleanValue: false,
                    inputType: 'text',
                    isBooleanValue: false
                }
            ];
        }

        currentItems.push(newItem);
        this.dispatchChangeEvent(currentItems);
    }

    handleRemoveItem(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        const updatedItems = currentItems.filter((item, i) => i !== index);
        this.dispatchChangeEvent(updatedItems);
    }

    handleItemChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const value = event.detail?.value ?? event.target?.value ?? '';

        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        currentItems[index].value = value;

        this.dispatchChangeEvent(currentItems);
    }

    handleBooleanItemChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const checked = event.target.checked;

        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        currentItems[index].booleanValue = checked;
        currentItems[index].value = String(checked);

        this.dispatchChangeEvent(currentItems);
    }

    handleClearAll() {
        this.dispatchChangeEvent([]);
    }

    // ===== HELPER METHODS =====

    getDefaultValue() {
        switch (this.itemType) {
            case 'number':
            case 'integer':
                return '0';
            case 'boolean':
                return 'false';
            case 'object':
                return '{}';
            default:
                return '';
        }
    }

    handleAddKeyValuePair(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        const item = currentItems[index];

        if (!item.keyValuePairs) {
            item.keyValuePairs = [];
        }

        const takenPairIds = new Set((item.keyValuePairs || []).map((pair) => pair.id));
        let nextPair = item.keyValuePairs.length;
        while (takenPairIds.has(`${index}-${nextPair}`)) {
            nextPair++;
        }
        const newPair = {
            id: `${index}-${nextPair}`,
            key: '',
            value: '',
            valueType: 'string',
            booleanValue: false,
            inputType: 'text',
            isBooleanValue: false
        };

        item.keyValuePairs.push(newPair);
        this.applyKeyValidation(item);
        this.dispatchChangeEvent(currentItems);
    }

    handleRemoveKeyValuePair(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const pairId = event.currentTarget.dataset.pairId;
        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        const item = currentItems[index];

        if (item.keyValuePairs) {
            item.keyValuePairs = item.keyValuePairs.filter((pair) => pair.id !== pairId);
        }

        this.applyKeyValidation(item);
        this.dispatchChangeEvent(currentItems);
    }

    handleObjectKeyChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const pairId = event.currentTarget.dataset.pairId;
        const newKey = event.detail?.value ?? event.target?.value ?? '';

        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        const item = currentItems[index];

        if (item.keyValuePairs) {
            const pairToUpdate = item.keyValuePairs.find((pair) => pair.id === pairId);
            if (pairToUpdate) {
                pairToUpdate.key = newKey;
            }
        }

        this.applyKeyValidation(item);
        this.dispatchChangeEvent(currentItems);
    }

    handleObjectValueChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const pairId = event.currentTarget.dataset.pairId;
        const newValue = event.detail?.value ?? event.target?.value ?? '';

        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        const item = currentItems[index];

        if (item.keyValuePairs) {
            const pairToUpdate = item.keyValuePairs.find((pair) => pair.id === pairId);
            if (pairToUpdate) {
                pairToUpdate.value = newValue;
            }
        }

        this.dispatchChangeEvent(currentItems);
    }

    handleObjectBooleanChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const pairId = event.currentTarget.dataset.pairId;
        const checked = event.target.checked;

        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        const item = currentItems[index];

        if (item.keyValuePairs) {
            const pairToUpdate = item.keyValuePairs.find((pair) => pair.id === pairId);
            if (pairToUpdate) {
                pairToUpdate.booleanValue = checked;
                pairToUpdate.value = String(checked);
            }
        }

        this.dispatchChangeEvent(currentItems);
    }

    handleObjectTypeChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const pairId = event.currentTarget.dataset.pairId;
        const newType = event.detail.value;

        const currentItems = JSON.parse(JSON.stringify(this.items)); // Deep clone
        const item = currentItems[index];

        if (item.keyValuePairs) {
            const pairToUpdate = item.keyValuePairs.find((pair) => pair.id === pairId);
            if (pairToUpdate) {
                pairToUpdate.valueType = newType;
                pairToUpdate.inputType = newType === 'number' ? 'number' : 'text';
                pairToUpdate.isBooleanValue = newType === 'boolean';

                // Convert existing value to new type
                if (newType === 'boolean') {
                    pairToUpdate.booleanValue = pairToUpdate.value === 'true' || pairToUpdate.value === true;
                    pairToUpdate.value = String(pairToUpdate.booleanValue);
                } else if (newType === 'number') {
                    const numVal = parseFloat(pairToUpdate.value);
                    pairToUpdate.value = isNaN(numVal) ? '0' : String(numVal);
                } else {
                    // String type - keep as is
                    pairToUpdate.value = String(pairToUpdate.value);
                }
            }
        }

        this.applyKeyValidation(item);
        this.dispatchChangeEvent(currentItems);
    }

    applyKeyValidation(item) {
        if (!item || !item.keyValuePairs) {
            return;
        }

        const keyCounts = {};
        item.keyValuePairs.forEach((pair) => {
            const trimmedKey = pair.key ? pair.key.trim() : '';
            if (trimmedKey) {
                keyCounts[trimmedKey] = (keyCounts[trimmedKey] || 0) + 1;
            }
        });

        item.keyValuePairs = item.keyValuePairs.map((pair) => {
            const trimmedKey = pair.key ? pair.key.trim() : '';
            const isEmpty = !trimmedKey;
            const isDuplicate = trimmedKey && keyCounts[trimmedKey] > 1;
            const hasKeyError = isEmpty || isDuplicate;

            return {
                ...pair,
                hasKeyError,
                keyErrorMessage: isEmpty ? 'Key is required.' : isDuplicate ? 'Duplicate key.' : '',
                keyInputClass: hasKeyError ? 'slds-form-element slds-has-error' : 'slds-form-element'
            };
        });
    }

    dispatchChangeEvent(items) {
        // Build JSON from the updated items and dispatch to parent
        const jsonValue = this.buildJsonValue(items);

        this.dispatchEvent(
            new CustomEvent('arraychange', {
                detail: {
                    value: jsonValue
                },
                bubbles: true,
                composed: true
            })
        );
    }
}
