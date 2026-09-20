# Running Windows programs on Auros — what is true

**Short version: assume your Windows programs do not come across. Some of them will. Find out which
ones before you move, not after.**

This page exists because of prohibition §4.2 — *never claim an app migrates when it doesn't* — and
because an overclaim here ends the company. A school that moves 180 machines on the strength of a
promise about their attendance software, and then discovers the promise was optimistic, does not file a
support ticket. They go back to Windows, they tell the other three schools in the district, and they are
right to.

Everything below is stated at or below what we have evidence for.

---

## The three-line version for a customer

1. Your **files** come across: documents, pictures, downloads, bookmarks, printers, Wi-Fi.
2. Your **programs** do not. A Windows program cannot be moved to a Linux computer, in the same way an
   iPhone app cannot be moved to a laptop. You install a replacement, and it is usually free.
3. A **compatibility layer** (Bottles/WINE) can run *some* Windows programs anyway. It is optional, it
   is not a guarantee, and it is slow on the hardware we sell into. Treat anything it runs as a bonus.

---

## Does not come across. Named, not footnoted.

| Software | Status | What we actually know |
|---|---|---|
| **Microsoft Office** (365 Business, 2021 Pro Plus, 365 ProPlus) | **Does not run** | WineHQ AppDB rates all three **Garbage**, read directly on 2026-09-20. Garbage is AppDB's lowest rating: the application does not function usefully. |
| **Adobe Photoshop** (CC 2019–2024) | **Does not run usefully** | AppDB rates every release in that range **Silver** — "has some problems for which there are no workarounds" — on small samples and stale Wine versions, with no 2025 or 2026 entry at all. We will not sell a school on a Silver rating from an old test. |
| **Adobe Creative Cloud** generally (Illustrator, InDesign, Premiere, Acrobat Pro) | **Does not run** | Same family of problems, plus the Creative Cloud installer itself. |
| Anything with a **USB licence dongle** | Does not run | The dongle needs a Windows kernel driver. There is no user-space substitute. |
| Anything that **installs its own driver** | Does not run | Scanners with vendor TWAIN drivers, lab instruments, card printers, some interactive whiteboards. |
| **Games with kernel-level anti-cheat** | Does not run | By design. The anti-cheat is a Windows kernel driver. |
| **Windows-only management agents** — asset tracking, exam lockdown browsers, some filtering clients | Does not run | And usually must not: these want kernel hooks. |
| **OneDrive desktop sync client** | Does not run | Files On-Demand placeholders are a Windows filesystem feature. Use OneDrive in a browser. |

### The honest answer when a customer needs Office

There are three, and none of them is WINE:

1. **Office on the web** in a browser — free, works today, and is what most school administrative work
   actually needs. Formatting-heavy documents and complex spreadsheets are where it disappoints.
2. **Keep one Windows machine** for the person who genuinely needs desktop Office, and migrate the other
   forty. This is the answer we give most often and it is not a failure.
3. **Do not migrate that user.** Also not a failure.

### Why we do not offer a Windows virtual machine

Winboat and WinApps run real Windows in a VM or container and forward its windows to the Linux desktop.
We do not offer them, per DECISIONS.md D16:

- they need a **Windows licence per device**, bought on top of the migration;
- their own floor is **4 GB of RAM and 32 GB of disk for the VM alone**, on laptops that have 4 GB in
  total;
- they are self-described beta.

Offering a school with 2012-era 4 GB laptops a Windows VM is not an honest option, so we do not put it
on the table at all.

---

## What Bottles/WINE does run, in our experience

The capability is **off unless your recipe turns it on**. When it is on, the image ships Bottles from
Flathub and creates one "Windows" bottle in each user's home directory the first time they log in.

Reasonable expectations:

- **Small, self-contained programs** — a utility that unzips into a folder and runs.
- **Older line-of-business software** written for Windows XP or 7 that never asked much of the machine.
- **Installers that predate modern .NET.** Newer .NET and anything wanting the Microsoft Store will
  fight you.
- **Simple 2D games** from the era the hardware is from.

Reasonable expectations about *performance*, which people forget to ask about: the machines this product
exists for are 2012–2018, frequently 4 GB of RAM, frequently a spinning disk, with integrated graphics.
WINE adds translation overhead on top of that. A program that was sluggish on Windows will not be
quicker here. **Expect slow, and test with the real file sizes you use, not a sample.**

---

## How to check your own software — before you commit

There is no button for this and we are not going to build one. DECISIONS.md D16 records why: WineHQ's
AppDB has **no API** — it is a web application currently sitting behind an anti-bot proof-of-work
challenge — and building "paste your app list and we will check it" would mean circumventing a control
its operators deliberately put there. A checker that quietly breaks the moment that control changes is
worse than no checker, because people would have trusted it.

So the procedure is manual, and it is short:

1. **Write down every program you actually open in a week.** Not the installed-programs list — the ones
   you use. It is usually five to nine, and it is never the list people expect.
2. **For each one, ask what it is really for.** "We use Publisher for the newsletter" often ends at
   Canva or LibreOffice Draw, not at making Publisher run.
3. **Look it up on the WineHQ Application Database** at `appdb.winehq.org`, by hand, in a browser.
   Read the rating *and its date*. A Platinum rating from 2019 on a version you do not run is not
   evidence about your 2026 machine. Ratings mean: Platinum/Gold — works, possibly with tweaks;
   Silver — problems with no workaround; Bronze/Garbage — no.
4. **Test the one that matters on one machine, doing the real task, end to end.** Print the invoice.
   Export the report. Open the biggest file you have. "It opened" is not "it works".
5. **Only then decide** how many machines to move, and keep a Windows machine for whatever failed.

Ask us during the sales conversation and we will look things up with you. We keep an internal table of
what we have actually seen work, and it is hand-written from real machines, which is why it is short and
why it is worth something.

---

## If it does not work

It is a normal outcome, not a fault, and there is usually a replacement that runs properly and costs
nothing. What we will not do is tell you it will probably be fine.
