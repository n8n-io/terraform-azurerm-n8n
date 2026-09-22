## ADDED Requirements

### Requirement: Certificate Common Name length

Both TLS helper submodules SHALL reject a `domain_name` longer than 64
characters at plan time, because it becomes the certificate Common Name
and RFC 5280 caps that field at 64 octets. Subject alternative names
SHALL keep the 253-character DNS limit.

#### Scenario: Reject an over-long Common Name

- **WHEN** `domain_name` exceeds 64 characters in `modules/tls-letsencrypt`
  or `modules/tls-self-signed`
- **THEN** the submodule SHALL fail at plan time naming the 64-character
  limit

#### Scenario: Accept a long SAN

- **WHEN** a `subject_alternative_names` entry is between 65 and 253
  characters with valid labels
- **THEN** the Let's Encrypt submodule SHALL accept it

### Requirement: Webhook subdomain label length

`examples/split-ingress`'s `webhook_subdomain` SHALL be a single DNS label
of at most 63 characters.

#### Scenario: Reject an over-long webhook label

- **WHEN** `webhook_subdomain` exceeds 63 characters
- **THEN** the example SHALL fail at plan time
