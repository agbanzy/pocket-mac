# Milestone-0 acceptance scenarios. Each names the verification layer that proves it:
#   A = PocketMacKit unit tests (swift test)   B = relay go test
#   C = PocketMacProbe live harness            D = full E2E (helper + iPhone/Simulator)

Feature: Pairing establishes an E2E-encrypted session
  Scenario: Successful pairing                    # A (handshake) + C/D (live)
    Given the helper is advertising over Bonjour
    And the app has the Mac's public key from the scanned QR / deep link
    When the initiator runs the Noise IK handshake
    Then both sides derive the same session key
    And the session is marked paired

  Scenario: Wrong PIN is rejected                 # A: HandshakeTests.wrongPINRejected
    When the pairing prologues (SAS) differ between the two sides
    Then the handshake's first AEAD open fails and no session is formed

  Scenario: Unpaired or revoked device refused    # A: LoopbackSessionTests.unauthorized/revoked
    Given a device whose PeerID is unknown or revoked
    When it tries to open a session
    Then the Mac never sends handshake message 2

Feature: Trackpad controls the cursor
  Scenario: Drag moves the cursor                 # C (deterministic) + D
    Given a paired, encrypted session
    When the app sends relative pointer-move deltas
    Then the Mac cursor position changes by the corresponding delta

Feature: Keyboard types text
  Scenario: Typing produces text                  # D (text in TextEdit)
    Given a paired, encrypted session
    When the app sends unicode-text frames
    Then the text appears in the focused Mac app

Feature: Action tiles
  Scenario: Tile launches an app                  # C/D
    Given a paired, encrypted session
    When the user taps the "Launch Music" tile
    Then Music.app is running
  Scenario: Media tile toggles playback           # D (manual-observe)
    When the user taps Play/Pause
    Then Music playback toggles

Feature: Session integrity
  Scenario: Replayed frame is rejected            # A: AEADChannelTests.replayRejected
    Given a paired session with counter at N
    When a frame with counter <= N is delivered
    Then the helper drops it and produces no input
  Scenario: Tampered frame is rejected            # A: AEADChannelTests.tamperedCiphertextFails
    When a ciphertext byte is flipped in transit
    Then AEAD authentication fails and the frame is dropped

Feature: The relay learns nothing
  Scenario: Blind forwarding                      # B: TestRelay_BlindForward / ZeroKnowledge
    Given two peers connected by the same pairing token
    When one sends opaque ciphertext (even non-protocol bytes)
    Then the other receives it byte-identical
    And the relay never imports crypto nor inspects the payload
