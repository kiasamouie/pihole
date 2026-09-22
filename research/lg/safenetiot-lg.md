# LG ACR — SafeNetIoT/ACR + IMC 2024 paper

Sources fetched: repo README (raw main), one repo listing, `trigger_validation_scripts/exp_lg.txt` (raw), arXiv abstract (2409.06203). Full paper PDF was NOT fetched (out of scope).

## Paper / repo

- **Paper:** "Watching TV with the Second-Party: A First Look at Automatic Content Recognition Tracking in Smart TVs" — Anselmi, Vekaria, D'Souza, Callejo, Mandalari, Shafiq. IMC 2024 (24th ACM Internet Measurement Conference, Madrid). DOI: 10.1145/3646547.3689013
- **arXiv:** https://arxiv.org/abs/2409.06203 (cs.CR, announced Sep 2024)
- **Repo:** https://github.com/SafeNetIoT/ACR — Python, AGPL-3.0, 15 commits, last push 2024-09-09, 23 stars. Folders: `trigger_validation_scripts/` (experiment.sh, `exp_lg.txt`, `exp_samsung.txt`), `analysis_scripts/`. PCAPs on a Google Drive link in the README.
- Experiment setup for LG (`exp_lg.txt`): TV MAC `b8:16:5f:ef:fb:58`, IR remote codes, scripted screen taps, test content incl. `lg_kids_channel` and `com.tuya.smart` app.

## LG model(s) tested

- **Not stated in any fetched source.** The abstract confirms experiments on "two major smart TV platforms: Samsung and LG"; the README and `exp_lg.txt` give no model name (only MAC + control codes). Exact model/webOS version is in the full paper PDF — not verified here.
- Coverage (from abstract): black-box audit of ACR client→server traffic; ACR is "Shazam-like" (periodic sampling of on-screen content matched against a content library); findings: ACR works even when the TV is used as a dumb external display (HDMI), opting out of privacy settings stops traffic to ACR servers, and ACR behavior differs between UK and US.

## LG ACR domains / endpoints

- **No LG domains are listed in the repo README or abstract** — the domain/endpoint identification lives in the paper body and the shared PCAPs.
- Domain that is reported as LG's ACR/online-tracking endpoint in the IMC 2024 paper and independently present in the community list (samsapti, see `github-lists-a.yaml`): `lgtvonline.lge.com` (medium confidence — consistent across sources, but exact path/port not verified without the PDF).
- Ports/payload types: **not verified from fetched sources**. The paper (and its PCAPs) cover the transport; check the PDF/Drive folder before assuming port or payload shape.

## Citations

```
G. Anselmi, Y. Vekaria, A. D'Souza, P. Callejo, A. M. Mandalari, and Z. Shafiq. 2024.
Watching TV with the Second-Party: A First Look at Automatic Content Recognition Tracking in Smart TVs.
In Proc. of the 24th ACM Internet Measurement Conference (IMC '24), Nov 4–6, 2024, Madrid, Spain.
ACM, New York, NY, USA, 13 pages. https://doi.org/10.1145/3646547.3689013
```
arXiv: https://arxiv.org/abs/2409.06203

## Gaps

1. Exact LG TV model + webOS version → needs paper PDF (Section: experimental setup).
2. Exact LG ACR endpoint path, port, payload format → needs paper PDF / PCAPs (Google Drive link in README).
3. ACM DL abstract page was Cloudflare-blocked; arXiv abstract used instead.
