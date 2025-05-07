/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
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
