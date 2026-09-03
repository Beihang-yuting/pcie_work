# Final BDF/address fixes

Config requests now map TL completer BDF to SVT `bus_number`,
`device_number`, and `function_number`, and decode reconstructs that BDF.
Three-DW memory requests reject non-zero upper address bits. Unit coverage
asserts BDF mapping; Chinese comments document the SVT field split.
