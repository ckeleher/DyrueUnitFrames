#!/usr/bin/env python3
"""British -> American spellings across the project.

Whole-word, case-preserving. Scans first and reports; only rewrites with
--apply, so the substitution list can be eyeballed before anything moves.

Deliberately NOT touched:
  Libs/                 vendored, never modified in place (SPEC 11.2)
  Documents/SPEC.md     authored requirement documents; rewording them would
  Documents/PLAN.md     put the record of what was asked out of step with it
"""
import io
import os
import re
import sys

# Stems only where a stem is unambiguous; explicit words where it is not.
PAIRS = [
    # -our -> -or
    ("behaviour", "behavior"), ("behaviours", "behaviors"),
    ("flavour", "flavor"), ("flavours", "flavors"),
    ("flavoured", "flavored"), ("flavouring", "flavoring"),
    ("armour", "armor"), ("honour", "honor"), ("honoured", "honored"),
    ("honours", "honors"), ("favour", "favor"), ("favours", "favors"),
    ("favoured", "favored"), ("labour", "labor"), ("neighbour", "neighbor"),
    ("neighbours", "neighbors"), ("rumour", "rumor"), ("harbour", "harbor"),
    ("valour", "valor"), ("humour", "humor"), ("odour", "odor"),
    ("vapour", "vapor"), ("vigour", "vigor"), ("savour", "savor"),
    ("endeavour", "endeavor"), ("splendour", "splendor"),

    # -ise -> -ize
    ("initialise", "initialize"), ("initialised", "initialized"),
    ("initialises", "initializes"), ("initialising", "initializing"),
    ("normalise", "normalize"), ("normalised", "normalized"),
    ("normalises", "normalizes"), ("normalising", "normalizing"),
    ("normalisation", "normalization"),
    ("customise", "customize"), ("customised", "customized"),
    ("customises", "customizes"), ("customising", "customizing"),
    ("recognise", "recognize"), ("recognised", "recognized"),
    ("recognises", "recognizes"), ("recognising", "recognizing"),
    ("organise", "organize"), ("organised", "organized"),
    ("organises", "organizes"), ("organising", "organizing"),
    ("realise", "realize"), ("realised", "realized"),
    ("realises", "realizes"), ("realising", "realizing"),
    ("serialise", "serialize"), ("serialised", "serialized"),
    ("synchronise", "synchronize"), ("synchronised", "synchronized"),
    ("prioritise", "prioritize"), ("prioritised", "prioritized"),
    ("optimise", "optimize"), ("optimised", "optimized"),
    ("optimises", "optimizes"), ("optimising", "optimizing"),
    ("optimisation", "optimization"), ("optimisations", "optimizations"),
    ("minimise", "minimize"), ("minimised", "minimized"),
    ("maximise", "maximize"), ("maximised", "maximized"),
    ("summarise", "summarize"), ("summarised", "summarized"),
    ("categorise", "categorize"), ("categorised", "categorized"),
    ("emphasise", "emphasize"), ("emphasised", "emphasized"),
    ("specialise", "specialize"), ("specialised", "specialized"),
    ("standardise", "standardize"), ("standardised", "standardized"),
    ("utilise", "utilize"), ("utilised", "utilized"),
    ("visualise", "visualize"), ("visualised", "visualized"),
    ("capitalise", "capitalize"), ("capitalised", "capitalized"),
    ("capitalisation", "capitalization"),
    ("generalise", "generalize"), ("generalised", "generalized"),
    ("itemise", "itemize"), ("memorise", "memorize"),
    ("randomise", "randomize"), ("randomised", "randomized"),
    ("stabilise", "stabilize"), ("stabilised", "stabilized"),
    ("authorise", "authorize"), ("authorised", "authorized"),
    ("apologise", "apologize"), ("characterise", "characterize"),
    ("criticise", "criticize"), ("modernise", "modernize"),
    ("penalise", "penalize"), ("publicise", "publicize"),
    ("symbolise", "symbolize"),

    # -yse -> -yze
    ("analyse", "analyze"), ("analysed", "analyzed"),
    ("analyses", "analyzes"), ("analysing", "analyzing"),
    ("paralyse", "paralyze"), ("catalyse", "catalyze"),

    # -re -> -er
    ("centre", "center"), ("centres", "centers"), ("centred", "centered"),
    ("centring", "centering"), ("metre", "meter"), ("metres", "meters"),
    ("fibre", "fiber"), ("theatre", "theater"), ("calibre", "caliber"),
    ("spectre", "specter"), ("lustre", "luster"), ("sombre", "somber"),

    # -ce -> -se
    ("licence", "license"), ("defence", "defense"), ("offence", "offense"),
    ("pretence", "pretense"), ("practise", "practice"),
    ("practised", "practiced"), ("practising", "practicing"),

    # doubled consonant
    ("cancelled", "canceled"), ("cancelling", "canceling"),
    ("labelled", "labeled"), ("labelling", "labeling"),
    ("modelled", "modeled"), ("modelling", "modeling"),
    ("travelled", "traveled"), ("travelling", "traveling"),
    ("signalled", "signaled"), ("signalling", "signaling"),
    ("totalled", "totaled"), ("fuelled", "fueled"),
    ("marvelled", "marveled"), ("levelled", "leveled"),
    ("channelled", "channeled"), ("channelling", "channeling"),

    # -ogue -> -og
    ("catalogue", "catalog"), ("catalogues", "catalogs"),
    ("dialogue", "dialog"), ("dialogues", "dialogs"),
    ("analogue", "analog"),

    # miscellaneous
    ("grey", "gray"), ("greys", "grays"), ("greyed", "grayed"),
    ("greyscale", "grayscale"),
    ("artefact", "artifact"), ("artefacts", "artifacts"),
    ("whilst", "while"), ("amongst", "among"),
    ("judgement", "judgment"), ("judgements", "judgments"),
    ("acknowledgement", "acknowledgment"),
    ("acknowledgements", "acknowledgments"),
    ("ageing", "aging"), ("programme", "program"),
    ("programmes", "programs"),
    ("enquire", "inquire"), ("enquiry", "inquiry"), ("enquiries", "inquiries"),
    ("mould", "mold"), ("moulded", "molded"), ("moulding", "molding"),
    ("sceptic", "skeptic"), ("sceptical", "skeptical"),
    ("manoeuvre", "maneuver"), ("storey", "story"),
    ("learnt", "learned"), ("spelt", "spelled"), ("dreamt", "dreamed"),
    ("speciality", "specialty"), ("specialities", "specialties"),
    ("aluminium", "aluminum"), ("draught", "draft"),
    ("cheque", "check"), ("kerb", "curb"), ("tyre", "tire"),
    ("plough", "plow"),
]

EXCLUDED_DIRS = {".git", "Libs", "venv", "__pycache__", "node_modules"}
EXCLUDED_FILES = {
    os.path.join("Documents", "SPEC.md"),
    os.path.join("Documents", "PLAN.md"),
}
EXTENSIONS = (".lua", ".md", ".ps1", ".toc", ".xml", ".py")


def match_case(british, american, found):
    """Return `american` wearing whatever case `found` had."""
    if found.isupper():
        return american.upper()
    if found[0].isupper():
        return american[0].upper() + american[1:]
    return american


def collect(root):
    files = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS]
        for n in sorted(names):
            if not n.endswith(EXTENSIONS):
                continue
            path = os.path.join(base, n)
            rel = os.path.relpath(path, root)
            if rel in EXCLUDED_FILES:
                continue
            files.append(path)
    return files


def main(argv):
    root = "."
    apply = "--apply" in argv

    # Longest first so "initialising" is not eaten by "initialise".
    pairs = sorted(PAIRS, key=lambda p: -len(p[0]))
    patterns = [(b, a, re.compile(r"\b" + b + r"\b", re.IGNORECASE)) for b, a in pairs]

    hits = {}
    changed = []

    for path in collect(root):
        with io.open(path, encoding="utf-8") as fh:
            src = fh.read()
        out = src
        for british, american, rx in patterns:
            def sub(m):
                hits.setdefault(british, [0, american])
                hits[british][0] += 1
                return match_case(british, american, m.group(0))
            out = rx.sub(sub, out)
        if out != src:
            changed.append(os.path.relpath(path, root).replace("\\", "/"))
            if apply:
                with io.open(path, "w", encoding="utf-8") as fh:
                    fh.write(out)

    if not hits:
        print("No British spellings found.")
        return 0

    print("%s:" % ("APPLIED" if apply else "FOUND (dry run, pass --apply)"))
    for british in sorted(hits, key=lambda k: -hits[k][0]):
        count, american = hits[british]
        print("  %-22s -> %-22s %d" % (british, american, count))
    print("\n%d file(s):" % len(changed))
    for c in changed:
        print("  " + c)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
