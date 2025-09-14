/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContextFormatterFactory creates appropriate context formatter instances based on the requested format strategy.
 * This factory pattern allows for easy extension and decoupling of formatter implementations.
 */
public inherited sharing class ContextFormatterFactory {
    /**
     * Creates a context formatter instance based on the specified format strategy.
     *
     * @param formatStrategy  The formatting approach ('XML', 'JSON', or 'StructuredText').
     * @return                An instance of IContextFormatter for the requested format.
     */
    public static IContextFormatter createFormatter(String formatStrategy) {
        if (String.isBlank(formatStrategy)) {
            // Default to StructuredText formatting
            return new StructuredTextContextFormatter();
        }

        if ('XML'.equalsIgnoreCase(formatStrategy)) {
            return new XmlContextFormatter();
        } else if ('JSON'.equalsIgnoreCase(formatStrategy)) {
            return new JsonContextFormatter();
        } else {
            // Default to StructuredText formatting
            return new StructuredTextContextFormatter();
        }
    }
}
