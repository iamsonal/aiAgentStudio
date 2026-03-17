/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * @description Optional channel plugin seam for resolving a participant key to a source record.
 */
public interface IChannelParticipantResolver {
    Id resolveSourceRecordId(String participantKey, Id explicitSourceRecordId);
}
