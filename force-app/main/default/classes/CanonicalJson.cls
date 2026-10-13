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

/**
 * Deterministic JSON serialization and case-sensitive SHA-256 hashing for
 * durable configuration and request identities.
 */
public without sharing class CanonicalJson {
    public static String serialize(Object value) {
        if (value instanceof Map<String, Object>) {
            Map<String, Object> source = (Map<String, Object>) value;
            List<String> keys = new List<String>(source.keySet());
            keys.sort();
            List<String> members = new List<String>();
            for (String key : keys) {
                members.add(JSON.serialize(key) + ':' + serialize(source.get(key)));
            }
            return '{' + String.join(members, ',') + '}';
        }
        if (value instanceof List<Object>) {
            List<String> items = new List<String>();
            for (Object item : (List<Object>) value) {
                items.add(serialize(item));
            }
            return '[' + String.join(items, ',') + ']';
        }
        return JSON.serialize(value);
    }

    /**
     * JSON with object keys in the order the maps hold them. JSON.serialize
     * does not keep that order, and a schema's property order is the order
     * an admin and the model read its inputs in.
     */
    public static String serializeInOrder(Object value, Boolean pretty) {
        JSONGenerator generator = JSON.createGenerator(pretty == true);
        writeInOrder(generator, value);
        return generator.getAsString();
    }

    private static void writeInOrder(JSONGenerator generator, Object value) {
        if (value instanceof Map<String, Object>) {
            Map<String, Object> source = (Map<String, Object>) value;
            generator.writeStartObject();
            for (String key : source.keySet()) {
                generator.writeFieldName(key);
                writeInOrder(generator, source.get(key));
            }
            generator.writeEndObject();
        } else if (value instanceof List<Object>) {
            generator.writeStartArray();
            for (Object item : (List<Object>) value) {
                writeInOrder(generator, item);
            }
            generator.writeEndArray();
        } else if (value == null) {
            generator.writeNull();
        } else {
            generator.writeObject(value);
        }
    }

    public static String sha256(String value) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(value))).toLowerCase();
    }

    public static Boolean hashMatches(String value, String expectedHash) {
        return value != null && expectedHash != null && expectedHash.equals(sha256(value));
    }
}
