/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * UuidUtils provides a utility method for generating RFC 4122-compliant Version 4 UUIDs in Apex.
 *
 * Responsibilities:
 *   - Generates cryptographically secure, random-based UUIDs suitable for unique identifiers in distributed systems.
 *   - Ensures output format and variant/version bits conform to RFC 4122 (Version 4).
 *
 * This class is stateless and thread-safe, and is intended for use wherever globally unique identifiers are required.
 */
public inherited sharing class UuidUtils {
    /**
     * Generates a cryptographically secure Version 4 UUID string following RFC 4122 specification.
     *
     * @return String A 36-character UUID in standard hyphenated format (xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx).
     * @throws None. Any unexpected error will propagate as an unhandled exception.
     *
     * Example output: 3f2504e0-4f89-41d3-9a0c-0305e82c3301
     */
    public static String generateUUID() {
        // Generate 128 bits of cryptographically secure random data
        Blob b = Crypto.generateAesKey(128);
        String h = EncodingUtil.convertToHex(b);

        // Calculate variant bits (10xx) for RFC 4122 compliance
        Integer variantValue = Math.mod(Math.abs(h.substring(16, 20).hashCode()), 4) + 8;
        String[] hexMap = new List<String>{ '8', '9', 'A', 'B' };
        String variantHex = hexMap[variantValue - 8];

        // Compose the UUID string in standard format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
        String uuid =
            h.substring(0, 8) +
            '-' +
            h.substring(8, 12) +
            '-4' + // Version 4 identifier
            h.substring(13, 16) +
            '-' +
            variantHex +
            h.substring(17, 20) +
            '-' +
            h.substring(20);

        // Debug output for troubleshooting (can be commented out in production)
        System.debug(LoggingLevel.DEBUG, '[UuidUtils] Generated UUID: ' + uuid);
        return uuid;
    }
}
