# vault_vault_delivery

The two media engines behind one MediaSource interface: chunked byte-range VOD, live transcode with simulcast, plus UplinkGovernor, backpressure polling and the viewer queue.

## Contract

- 100% test coverage target on UplinkGovernor and the chunk protocol (mandated).
- Every magic number here is a named constant with a comment.

