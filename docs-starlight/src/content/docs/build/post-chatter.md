---
title: Post to Chatter
description: Let an agent post a text message to a record's feed, a user, or a Chatter group.
---

A **Post to Chatter** tool posts one plain-text message. You choose where it goes. The agent writes only the text.

## Build one

1. Turn on Chatter, and feed tracking on the object you post to.
2. Create an Agent Tool with Tool Type `PostChatter`.
3. Under **Post To**, choose where posts go:

   | Post To | Implementation Configuration |
   | --- | --- |
   | The run's record | Blank |
   | A user or a group | `{"targetId": "0F9..."}`, chosen with the picker |
   | Another record whose feed is tracked | `{"targetId": "500..."}` |

4. Save. Core builds the one input, `messageText`, on each run. Input Schema stays blank.

## Limits

- One message per call, up to 10,000 characters.
- Plain text. Mentions and rich text are not supported.
- The post is made as the run's user: the execution user, or the person who started the run.

The tool returns the new feed item's Id. It only changes this org, so a failed post is undone and the agent gets the error.
