# Publication boundary

Publish code, generic documentation and synthetic test data only. Local source
captures, screenshots of live accounts, configuration, credentials, location,
vehicle identifiers/specifications associated with a person and private
verification notes must remain outside Git.

Before publication, inspect every outgoing commit and author/committer metadata,
not just HEAD. Run a secret scanner over the full outgoing range; inspect images
and metadata as well as text. A passing credential scanner does not detect all
personal context. Review fixture provenance and generated bundles separately.
Use the repository owner's GitHub noreply author identity.

If private material exists in unpushed commits, preserve it locally and prepare
a clean branch based on the last public commit. Deleting the file in a later
commit does not remove it from the branch history. Public history changes,
credential rotation and releases require separate explicit authorization.
