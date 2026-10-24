"""Place waiting exam-map chapters on the local syllabus list.

A waiting chapter is attached to one class 11 or 12 row when it is the same
topic. A chapter that covers two syllabus chapters is shown on its own, so its
questions are available and are not filed under only one of them.

Members touched here are marked manual, so a later rebuild keeps the decision.
"""
from __future__ import annotations

import re
import sys

from pymongo import MongoClient

LOCAL = "mongodb://127.0.0.1:27017"
DB_NAME = "papermantra"

# Chapter title -> syllabus rows to try, in order. Standard keeps class 11 and 12 apart.
ATTACH: dict[str, list[tuple[str, str]]] = {
    "Alcohols, Phenols and Ethers": [("12", "Alcohols, phenols and ethers")],
    "Alcohol Phenols And Ethers": [("12", "Alcohols, phenols and ethers")],
    "Aldehydes, Ketones and Carboxylic Acids": [("12", "Aldehydes, Ketones and Carboxylic Acids.")],
    "Aldehyde And Ketone": [("12", "Aldehydes, Ketones and Carboxylic Acids.")],
    "Carboxylic Acids And Its Derivatives": [("12", "Aldehydes, Ketones and Carboxylic Acids.")],
    "Atomic Structure": [("11", "Structure of Atom"), ("12", "Atoms")],
    "Basics Of Organic Chemistry": [
        ("11", "Organic Chemistry: Some Basic Principles and Techniques"),
        ("11", "Basic Principles and Techniques"),
    ],
    "Biomolecules": [("12", "Bio Molecules")],
    "Chemical Equilibrium": [("11", "Equilibrium")],
    "Chemical Kinetics And Nuclear Chemistry": [("12", "Chemical kinetics")],
    "Nuclear Chemistry": [("12", "Chemical kinetics")],
    "Classification of Elements and Periodicity": [
        ("11", "Classification of Elements and Periodicity in Properties")
    ],
    "Periodic Table And Periodicity": [
        ("11", "Classification of Elements and Periodicity in Properties")
    ],
    "Compounds Containing Nitrogen": [
        ("12", "Amines"),
        ("12", "Organic Compounds Containing Nitrogen"),
    ],
    "Organic Compounds Containing Nitrogen": [
        ("12", "Amines"),
        ("12", "Organic Compounds Containing Nitrogen"),
    ],
    "Coordination Compounds": [("12", "Co-ordination Compounds")],
    "Ionic Equilibrium": [("11", "Equilibrium")],
    "Ionic Equilibrum": [("11", "Equilibrium")],
    "Isomerism in Organic Compounds": [
        ("11", "Organic Chemistry: Some Basic Principles and Techniques"),
        ("11", "Basic Principles and Techniques"),
    ],
    "Isomerism": [("11", "Basic Principles and Techniques")],
    "Iupac Nomenclature": [("11", "Basic Principles and Techniques")],
    "General Organic Chemistry": [
        ("11", "Basic Principles and Techniques"),
        ("11", "Organic Chemistry: Some Basic Principles and Techniques"),
    ],
    "Organic Chemistry - Some Basic Principles and": [
        ("11", "Organic Chemistry: Some Basic Principles and Techniques")
    ],
    "Some Basic Principles of Organic Chemistry": [
        ("11", "Organic Chemistry: Some Basic Principles and Techniques"),
        ("11", "Basic Principles and Techniques"),
    ],
    "Some Basic Concepts Of Organic Chemistry": [
        ("11", "Organic Chemistry: Some Basic Principles and Techniques")
    ],
    "Organic Compounds Containing Halogens": [("12", "Haloalkanes and Haloarenes")],
    "Practical Organic Chemistry": [
        ("12", "Practical Chemistry"),
        ("11", "Basic Principles and Techniques"),
    ],
    "Purification and Characterization of Organic Compounds": [
        ("11", "Organic Chemistry: Some Basic Principles and Techniques")
    ],
    "Salt Analysis": [("12", "Practical Chemistry")],
    "Some Basic Concepts of Chemistry": [("11", "Some Basic Concepts in Chemistry")],
    "Some p-Block Elements": [("11", "The p-Block Elements")],
    "d-and f-Block Elements": [("12", "D - And f-Block Elements")],
    "p-Block Elements": [("12", "p-Block Elements")],
    "Chemical Bonding and Molecular Structure": [("11", "Chemical Bonding")],
    "Redox Reactions": [("11", "Redox Reaction")],
    "Liquid Solution": [("12", "Solutions")],
    "3d Geometry": [("12", "Three - Dimensional Geometry")],
    "Three-Dimensional Geometry": [("12", "Three - Dimensional Geometry")],
    "Application of Integrals": [("12", "Applications of the Integrals")],
    "Application of Derivatives": [("12", "Applications of Derivatives"), ("12", "Application of Derivatives")],
    "Area Under The Curves": [("12", "Applications of the Integrals")],
    "Circle": [("11", "Conic Sections")],
    "Circles": [("11", "Conic Sections")],
    "Ellipse": [("11", "Conic Sections")],
    "Hyperbola": [("11", "Conic Sections")],
    "Parabola": [("11", "Conic Sections")],
    "Ellipse and Hyperbola": [("11", "Conic Sections")],
    "Complex Number": [("11", "Complex Numbers and Quadratic Equations"), ("11", "Complex Numbers")],
    "Complex Numbers": [("11", "Complex Numbers and Quadratic Equations"), ("11", "Complex Numbers")],
    "Quadratic Equation And Inequalities": [("11", "Complex Numbers and Quadratic Equations")],
    "Quadratic Equations": [("11", "Complex Numbers")],
    "Theory of Equations": [("11", "Complex Numbers and Quadratic Equations")],
    "Theory of Equations and Inequations": [("11", "Complex Numbers and Quadratic Equations")],
    "Coordinate System and Straight Lines": [("11", "Straight Lines")],
    "Straight Lines And Pair Of Straight Lines": [("11", "Straight Lines"), ("11", "Straight Line")],
    "Definite Integrals": [("12", "Integrals")],
    "Definite Integration": [("12", "Integrals")],
    "Definite Integration and Area": [("12", "Integrals")],
    "Indefinite Integrals": [("12", "Integrals")],
    "Indefinite Integration": [("12", "Integrals")],
    "Differentiation": [("12", "Continuity and Differentiability")],
    "Methods of Differentiation": [("12", "Continuity and Differentiability")],
    "Limits": [("11", "Limits and Derivatives"), ("11", "Limits")],
    "Limits Continuity And Differentiability": [("12", "Continuity and Differentiability")],
    "Functions": [("12", "Relations and Functions")],
    "Sets And Relations": [("11", "Relations & Functions"), ("12", "Relations and Functions")],
    "Sets, Relations and Functions": [("11", "Relations & Functions"), ("12", "Relations and Functions")],
    "Monotonicity and Extremum of Functions": [("12", "Application of Derivatives")],
    "Permutation and Combination": [("11", "Permutations and Combinations")],
    "Progression and Series": [("11", "Sequences and Series")],
    "Height And Distance": [("11", "Trigonometric Functions")],
    "Properties Of Triangle": [("11", "Trigonometric Functions")],
    "Properties of Triangle and Height and Distance": [("11", "Trigonometric Functions")],
    "Properties Of Triangles": [("11", "Trigonometry-II")],
    "Trigonometric Equations": [("11", "Trigonometric Functions"), ("11", "Trigonometry-II")],
    "Trigonometric Functions And Equations": [("11", "Trigonometric Functions")],
    "Trigonometric Ratio And Identites": [("11", "Trigonometric Functions")],
    "Trigonometric Ratios and Identities": [("11", "Trigonometric Functions"), ("11", "Trigonometry-II")],
    "Trigonometry": [("11", "Trigonometric Functions")],
    "Vector Algebra": [("12", "Vectors"), ("11", "Vectors")],
    "Inverse Trigonometric Functions": [
        ("12", "Inverse Trigonometric Functions"),
        ("12", "Inverse Trignometric Functions"),
    ],
    "Behaviour of Perfect Gas and Kinetic Theory": [("11", "Kinetic Theory of Gas")],
    "Capacitor": [("12", "Electrostatic Potential and Capacitance"), ("12", "Electrostatics")],
    "Center Of Mass": [("11", "System of Particles and Rotational Motion")],
    "Center Of Mass And Collision": [("11", "System of Particles and Rotational Motion")],
    "Centre of Mass, Conservation of Linear Momentum and Collision": [
        ("11", "System of Particles and Rotational Motion")
    ],
    "Circular Motion": [("11", "Motion in a Plane")],
    "Dual Nature Of Radiation": [("12", "Dual Nature of Matter")],
    "Dual Nature of Matter and Radiation": [("12", "Dual Nature of Matter")],
    "Dual Nature of Radiation and Matter": [("12", "Dual Nature of Matter")],
    "Elasticity": [("11", "Mechanical Properties of Solids")],
    "Electric Charge and Field": [("12", "Electric Charges and Fields")],
    "Electric Potential and Capacitance": [("12", "Electrostatic Potential and Capacitance")],
    "Electric Resistance and Simple Circuits": [("12", "Current Electricity")],
    "Heating Effect of Current and Electrical Measuring Instruments": [("12", "Current Electricity")],
    "Electronic Devices": [
        ("12", "Solids, Semi Conductor Electronic Materials, Devices and Simple Circuits")
    ],
    "Semiconductor Electronics": [
        ("12", "Solids, Semi Conductor Electronic Materials, Devices and Simple Circuits"),
        ("11", "Semiconductors"),
    ],
    "Semiconductor Devices And Logic Gates": [("11", "Semiconductors")],
    "Fluid Mechanics, Surface Tension and Viscosity": [("11", "Mechanical Properties of Fluids")],
    "Geometrical Optics": [("12", "Ray Optics and Optical Instruments")],
    "Ray Optics": [("12", "Ray Optics and Optical Instruments"), ("11", "Optics")],
    "Wave Optics": [("12", "Wave Optics"), ("11", "Optics")],
    "Nuclear Physics": [("12", "Nuclei")],
    "Motion in One Dimension": [("11", "Motion in a Straight Line")],
    "Motion in Two Dimension": [("11", "Motion in a Plane")],
    "Motion of System of Particles and Rigid Body": [("11", "System of Particles and Rotational Motion")],
    "Rotational Dynamics": [("11", "System of Particles and Rotational Motion")],
    "Rotational Motion": [("11", "System of Particles and Rotational Motion")],
    "Oscillation and Simple Harmonic Motion": [("11", "Oscillations")],
    "Simple Harmonic Motion": [("11", "Oscillations")],
    "Physical World and Measurement": [("11", "Units and Measurement")],
    "Units And Measurements": [("11", "Units and Measurement")],
    "Units, Dimensions and Measurement": [("11", "Units and Measurement")],
    "Thermal Expansion, Calorimetry and Transmission of Heat": [("11", "Thermal Properties of Matter")],
    "Magnetic Properties Of Matter": [("12", "Magnetism and Matter")],
    "Magnetism and Matter": [("12", "Magnetism and Matter"), ("12", "Magnetic Effects of Current and Magnetism")],
    "Magnetics": [("12", "Moving Charges and Magnetism")],
    "Source and Effects of Magnetic Field": [("12", "Moving Charges and Magnetism")],
    "Moving Charges And Magnetism": [("12", "Moving Charges and Magnetism"), ("12", "Magnetic Effects of Current and Magnetism")],
    "Newton's Laws of Motion (With Friction) and Dynamics of Circular Motion": [("11", "Laws of Motion")],
    "Newton's Laws of Motion(Without Friction)": [("11", "Laws of Motion")],
    "Wave and Acoustics": [("11", "Waves")],
    "Waves": [("11", "Waves"), ("11", "Sound")],
    "Work Power And Energy": [("11", "Work, Energy and Power")],
    "Work, Energy and Power": [("11", "Work, Energy and Power")],
    "Alternating Current": [
        ("12", "Alternating Current"),
        ("12", "Electromagnetic Induction and Alternating Currents"),
    ],
    "Electromagnetic Induction": [
        ("12", "Electromagnetic Induction"),
        ("12", "Electromagnetic Induction and Alternating Currents"),
    ],
    "Animal Kingdom - Chordates": [("11", "Animal Kingdom")],
    "Animal Kingdom -Nonchordates": [("11", "Animal Kingdom")],
    "Animal Tissues": [("11", "Structural Organisation in Animals")],
    "Morphology and Anatomy of Animals": [("11", "Structural Organisation in Animals")],
    "Applications of Biotechnology": [("12", "Biotechnology and its Applications")],
    "Biodiversity and Conservation": [("12", "Biodiversity and its Conservation")],
    "Body Fluids And Its Circulation": [("11", "Body Fluids and Circulation")],
    "Breathing and Exchange of Gases": [("11", "Breathing and Exchange of Gases")],
    "Cell The Unit of Life": [("11", "Cell : The Unit of Life")],
    "Cell and Basic Unit of Life": [("11", "Cell : The Unit of Life")],
    "Human Health and Disease": [("12", "Human Health and Diseases")],
    "Kingdom Fungi": [("11", "Biological Classification")],
    "Kingdom Monera": [("11", "Biological Classification")],
    "Kingdom Protista": [("11", "Biological Classification")],
    "Locomotion and Movement": [("11", "Locomotion and Movement")],
    "Neural Control and Coordination": [("11", "Neural Control and Coordination")],
    "Plant Growth & Development & Plant Movement": [("11", "Plants Growth and Development")],
    "Plant Growth and Development": [("11", "Plants Growth and Development")],
    "Principles of Inheritance and Variations": [("12", "Principles of Inheritance and Variation")],
}

# These titles cover more than one syllabus chapter, so they stay as their own row.
OWN = {
    "Atoms and Nuclei",
    "Electrostatics",
    "Electromagnetic Induction and Alternating Currents",
    "Heat And Thermodynamics",
    "Kinematics",
    "Kinetic Theory of Gases and Thermodynamics",
    "Magnetic Effects of Current and Magnetism",
    "Optics",
    "Oscillations and Waves",
    "Properties Of Matter",
    "Properties of Bulk Matter",
    "Matrices and Determinants",
    "Logarithm",
    "Logarithms",
    "Sets, Inequalities, Modulus and Logarithm",
    "Binomial Theorem",
    "Sequences and Series",
    "Statistics",
    "Fluid Mechanics",
    "Motion",
    "Units And Measurement And Dimensions",
    "Thermodynamics",
}


def norm(value: str) -> str:
    text = (value or "").lower().replace("&", " and ")
    text = text.replace("\ufffd", "")
    text = re.sub(r"['’‘`]", "", text)
    text = re.sub(r"(?<=[a-z0-9])[^a-z0-9\s]+(?=[a-z0-9])", "", text)
    text = re.sub(r"[^a-z0-9]+", " ", text)
    text = re.sub(r"\b(the|of|and|in|a|an)\b", " ", text)
    text = " ".join(text.split())
    text = text.replace("bio molecules", "biomolecules")
    text = text.replace("d f block", "dfblock")
    text = text.replace("s block", "sblock").replace("p block", "pblock")
    text = text.replace("trignometric", "trigonometric")
    text = text.replace("threedimensional", "three dimensional")
    return " ".join(text.split())


ATTACH_BY_NORM = {norm(name): targets for name, targets in ATTACH.items()}
OWN_NORMS = {norm(name) for name in OWN}


def find_target(rows: list[dict], allowed: set[str], subject: str, standard: str, title: str):
    want = norm(title)
    hits = [
        row
        for row in rows
        if row.get("mapKey") in allowed
        and row.get("subject") == subject
        and str(row.get("standard") or "") == standard
        and norm(row.get("chapterName") or "") == want
    ]
    return hits[0] if hits else None


def refresh(row: dict) -> None:
    members = row.get("members") or []
    row["memberIds"] = [member["chapterId"] for member in members if member.get("chapterId")]
    row["questionCount"] = sum(int(member.get("questionCount") or 0) for member in members)
    row["bookLabels"] = sorted({member["bookLabel"] for member in members if member.get("bookLabel")})


def main() -> None:
    apply = "--apply" in sys.argv
    db = MongoClient(LOCAL, serverSelectionTimeoutMS=8000)[DB_NAME]
    for exam in ["JEE", "NEET", "MHTCET"]:
        doc = db.exam_chapter_maps.find_one({"exam": exam})
        if not doc:
            continue
        rows = doc.get("rows") or []
        allowed = {
            row["mapKey"]
            for row in rows
            if row.get("teacherVisible") and not row.get("needsReview")
        }
        attached = 0
        shown = 0
        for row in list(rows):
            if not row.get("needsReview"):
                continue
            name = row.get("chapterName") or ""
            key = norm(name)
            subject = row.get("subject") or ""
            target = None
            label = "own"
            if key not in OWN_NORMS:
                for standard, title in ATTACH_BY_NORM.get(key, []):
                    target = find_target(rows, allowed, subject, standard, title)
                    if target is not None:
                        label = f"{standard} {target.get('chapterName')}"
                        break
            books = sorted({member.get("bookName") or "" for member in row.get("members") or []})
            print(f"{exam}\t{subject}\t{name}\t{row.get('questionCount')}\t{','.join(books)}\t->\t{label}")
            if not apply:
                continue
            for member in row.get("members") or []:
                member["manual"] = True
                member["matchedBy"] = "manual"
            if target is None:
                row["teacherVisible"] = True
                row["needsReview"] = False
                row["visibilityManual"] = True
                shown += 1
                continue
            existing = {member.get("chapterId") for member in target.get("members") or []}
            for member in row.get("members") or []:
                if member.get("chapterId") in existing:
                    continue
                target.setdefault("members", []).append(member)
                existing.add(member.get("chapterId"))
            row["members"] = []
            refresh(target)
            attached += 1
        if not apply:
            continue
        kept = [row for row in rows if row.get("members")]
        for row in kept:
            refresh(row)
        kept.sort(key=lambda row: (row.get("subject") or "", row.get("standard") or "9", row.get("chapterName") or ""))
        db.exam_chapter_maps.update_one(
            {"_id": doc["_id"]},
            {"$set": {"rows": kept, "rowCount": len(kept)}},
        )
        review = sum(1 for row in kept if row.get("needsReview"))
        visible = sum(1 for row in kept if row.get("teacherVisible"))
        print(f"SAVED {exam} attached-rows={attached} shown-as-own={shown} visible={visible} review={review}")


if __name__ == "__main__":
    main()
