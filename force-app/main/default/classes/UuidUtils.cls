/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Utility for generating UUIDs.
 */
public inherited sharing class UuidUtils {
    /**
     * @description Generates a Version 4 UUID.
     * @return String representing the UUID.
     */
    public static String generateUUID() {
        Blob b = Crypto.generateAesKey(128);
        String h = EncodingUtil.convertToHex(b);
        Integer variantValue = Math.mod(Math.abs(h.substring(16, 20).hashCode()), 4) + 8;
        String[] hexMap = new List<String>{ '8', '9', 'A', 'B' };
        String variantHex = hexMap[variantValue - 8];
        return h.substring(0, 8) +
            '-' +
            h.substring(8, 12) +
            '-4' +
            h.substring(13, 16) +
            '-' +
            variantHex +
            h.substring(17, 20) +
            '-' +
            h.substring(20);
    }
}
