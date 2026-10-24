"""Build admin-controlled exam chapter maps in local Mongo.

Each exam gets one document in exam_chapter_maps. A row is one syllabus
chapter. Book chapters that share its canonical code are members of that row.
A book chapter whose title matches a class 11 or 12 syllabus chapter is
attached there too. Anything else stays its own row, so questions are not hidden.

Re-running replaces generated rows and keeps members marked manual.
"""
from __future__ import annotations

import re
from collections import defaultdict
from datetime import datetime, timezone

from pymongo import MongoClient

LOCAL = "mongodb://127.0.0.1:27017"
DB_NAME = "papermantra"

STRICT = {
    "kcetpcm": "KCET PCM",
    "kcetpcb": "KCET PCB",
    "eamcetpcm": "EAMCET PCM",
    "eamcetam": "EAMCET AM",
    "topselectedpcm": "Top Selected PCM",
    "topselectedpcb": "Top Selected PCB",
    "foundation": "Foundation",
    "class6": "Class 6",
    "class7": "Class 7",
    "class8": "Class 8",
    "class9": "Class 9",
    "class10": "Class 10",
}


def norm_key(value: str) -> str:
    return re.sub(r"[\s_-]+", "", (value or "").strip().lower())


def norm_name(value: str) -> str:
    return " ".join((value or "").strip().lower().split())


def canonical_exam(name: str) -> str:
    key = norm_key(name)
    if not key:
        return ""
    if "mhtcet" in key or "mhcet" in key:
        return "MHTCET"
    if "maharashtra" in key and "board" in key:
        return "Maharashtra Board"
    if key in STRICT:
        return STRICT[key]
    if "eapcet" in key:
        return "EAPCET"
    if "eamcet" in key:
        return "EAMCET"
    if key == "jeemain":
        return "JEE Main"
    if key == "jeeadvanced":
        return "JEE Advanced"
    if key == "jee":
        return "JEE"
    if key == "neet":
        return "NEET"
    return (name or "").strip()


def subject_base(subject: dict) -> str:
    raw = subject.get("subjectName") or ""
    match = re.match(r"^(.+?)\s*\(\d{1,2}(?:th|st|nd|rd)?\)\s*$", raw, re.I)
    if match:
        return match.group(1).strip()
    return raw.strip()


def book_label(subject: dict) -> str:
    standard = str(subject.get("standard") or "").strip()
    if standard:
        return standard
    raw = subject.get("subjectName") or ""
    match = re.search(r"\((\d{1,2}(?:th|st|nd|rd)?)\)\s*$", raw, re.I)
    return match.group(1) if match else ""


def is_top_selected(group: dict) -> bool:
    names = [group.get("groupName") or ""]
    for exam in group.get("groupedBooks") or []:
        names.append(exam.get("examName") or "")
    return any(norm_key(name).startswith("topselected") for name in names)


def visible_group(group: dict) -> bool:
    if group.get("questionPaperEnabled") is False:
        return False
    visible = group.get("learnerVisible")
    if isinstance(visible, bool):
        return visible
    return not is_top_selected(group)


def stored_count(row: dict | None) -> int:
    if not row:
        return 0
    mcq = row.get("mcqCount")
    if isinstance(mcq, (int, float)) and mcq > 0:
        return int(mcq)
    total = row.get("questionCount")
    if isinstance(total, (int, float)) and total > 0:
        return int(total)
    return 0


def class_standard(code: str, canon: dict | None) -> str:
    standards = [str(item) for item in ((canon or {}).get("standards") or [])]
    for item in standards:
        if item in ("11", "12"):
            return item
    match = re.search(r"class(11|12)", code or "")
    return match.group(1) if match else ""


def main() -> None:
    db = MongoClient(LOCAL, serverSelectionTimeoutMS=8000)[DB_NAME]
    groups = list(db.master_book_groups.find())
    subjects = {str(row["_id"]): row for row in db.master_subjects.find()}
    books = {str(row["_id"]): row for row in db.master_books.find()}
    chapters = {str(row["_id"]): row for row in db.master_chapters.find()}
    by_subject: dict[str, list[dict]] = defaultdict(list)
    for chapter in chapters.values():
        by_subject[str(chapter.get("subjectId"))].append(chapter)
    counts = {
        str(row.get("chapterId")): row
        for row in db.question_count_details.find()
        if row.get("chapterId")
    }
    canon = {
        row.get("code"): row
        for row in db.syllabus_canonical_chapters.find()
        if row.get("code")
    }
    links_by_chapter: dict[str, dict] = {}
    for link in db.syllabus_source_links.find():
        chapter_id = str(link.get("chapterId") or "")
        if chapter_id:
            links_by_chapter[chapter_id] = link

    exams: dict[str, set[str]] = defaultdict(set)
    for group in groups:
        if not visible_group(group):
            continue
        for exam in group.get("groupedBooks") or []:
            label = canonical_exam(exam.get("examName") or "")
            if not label:
                continue
            for subject_id in exam.get("subjectIds") or []:
                if str(subject_id) in subjects:
                    exams[label].add(str(subject_id))

    now = datetime.now(timezone.utc)
    written = []
    for exam, subject_ids in sorted(exams.items()):
        pool = []
        for subject_id in subject_ids:
            pool.extend(by_subject.get(subject_id) or [])

        class_rows: dict[str, dict] = {}
        name_index: dict[tuple[str, str], str] = {}
        for chapter in pool:
            link = links_by_chapter.get(str(chapter["_id"]))
            code = (link or {}).get("canonicalCode") or ""
            row = canon.get(code)
            standard = class_standard(code, row)
            if not standard:
                continue
            subject = subjects.get(str(chapter.get("subjectId"))) or {}
            base = (row or {}).get("subject") or subject_base(subject)
            display = (row or {}).get("name") or chapter.get("chapterName") or "Chapter"
            if code not in class_rows:
                class_rows[code] = blank_row(code, display, base, standard)
                name_index[(norm_name(base), norm_name(display))] = code

        rows: dict[str, dict] = dict(class_rows)
        attached = 0
        own = 0
        for chapter in pool:
            chapter_id = str(chapter["_id"])
            if any(chapter_id in row["memberIds"] for row in rows.values() if chapter_id in {m["chapterId"] for m in row["members"]}):
                continue
            link = links_by_chapter.get(chapter_id)
            code = (link or {}).get("canonicalCode") or ""
            subject = subjects.get(str(chapter.get("subjectId"))) or {}
            base = subject_base(subject)
            title = chapter.get("chapterName") or "Chapter"
            target = code if code in rows else ""
            matched = "canonical" if target else ""
            if not target:
                target = name_index.get((norm_name(base), norm_name(title)), "")
                matched = "title" if target else ""
            if target:
                add_member(rows[target], chapter, subject, books, counts, matched)
                attached += 1
                continue
            key = code or f"chapter:{chapter_id}"
            if key not in rows:
                canon_row = canon.get(code) or {}
                rows[key] = blank_row(
                    key,
                    canon_row.get("name") or title,
                    canon_row.get("subject") or base,
                    class_standard(code, canon_row),
                )
            add_member(rows[key], chapter, subject, books, counts, "own")
            own += 1

        # Chapters that opened a class row were not counted by the second loop
        # when the row was created before they were visited. Add any missing
        # pool chapter whose canonical code is a class row.
        for chapter in pool:
            chapter_id = str(chapter["_id"])
            if placed(rows, chapter_id):
                continue
            link = links_by_chapter.get(chapter_id)
            code = (link or {}).get("canonicalCode") or ""
            if code in rows:
                subject = subjects.get(str(chapter.get("subjectId"))) or {}
                add_member(rows[code], chapter, subject, books, counts, "canonical")

        ordered = []
        for row in rows.values():
            if not row["members"]:
                continue
            row["members"].sort(key=lambda member: (member.get("bookLabel") or "", member.get("bookName") or "", member.get("chapterName") or ""))
            row["memberIds"] = [member["chapterId"] for member in row["members"]]
            row["questionCount"] = sum(member["questionCount"] for member in row["members"])
            row["bookLabels"] = sorted({member["bookLabel"] for member in row["members"] if member.get("bookLabel")})
            class_exam = exam not in {"Foundation"} and not exam.startswith("Class ")
            row["teacherVisible"] = (not class_exam) or row.get("standard") in {"11", "12"}
            row["needsReview"] = not row["teacherVisible"]
            primary = choose_primary(row["members"])
            row["id"] = primary["chapterId"]
            row["subjectId"] = primary["subjectId"]
            row["bookId"] = primary.get("bookId")
            ordered.append(row)
        ordered.sort(key=lambda row: (row.get("subject") or "", row.get("standard") or "9", row.get("chapterName") or ""))

        manual = preserved_manual(db, exam)
        if manual:
            ordered = apply_manual(ordered, manual)

        db.exam_chapter_maps.replace_one(
            {"exam": exam},
            {
                "exam": exam,
                "generatedAt": now,
                "source": "syllabus-links",
                "rowCount": len(ordered),
                "rows": ordered,
            },
            upsert=True,
        )
        visible = [row for row in ordered if row.get("teacherVisible")]
        review = [row for row in ordered if row.get("needsReview")]
        visible_questions = sum(row["questionCount"] for row in visible)
        review_questions = sum(row["questionCount"] for row in review)
        written.append((exam, len(visible), len(review), visible_questions, review_questions))

    print("exam\tvisible-chapters\treview-chapters\tvisible-questions\treview-questions")
    for exam, visible, review, visible_questions, review_questions in written:
        print(f"{exam}\t{visible}\t{review}\t{visible_questions}\t{review_questions}")


def blank_row(key: str, name: str, subject: str, standard: str) -> dict:
    return {
        "mapKey": key,
        "canonicalCode": key if not str(key).startswith("chapter:") else "",
        "chapterName": name,
        "name": name,
        "subject": subject,
        "standard": standard,
        "members": [],
        "memberIds": [],
    }


def add_member(row, chapter, subject, books, counts, how: str) -> None:
    chapter_id = str(chapter["_id"])
    if any(member["chapterId"] == chapter_id for member in row["members"]):
        return
    book = books.get(str(subject.get("bookId"))) or {}
    row["members"].append(
        {
            "chapterId": chapter_id,
            "chapterName": chapter.get("chapterName") or row["chapterName"],
            "subjectId": str(chapter.get("subjectId") or ""),
            "subjectName": subject.get("subjectName") or "",
            "bookId": str(subject.get("bookId") or ""),
            "bookName": book.get("bookName") or book.get("name") or "",
            "bookLabel": book_label(subject),
            "questionCount": stored_count(counts.get(chapter_id)),
            "matchedBy": how,
            "manual": False,
        }
    )


def placed(rows: dict, chapter_id: str) -> bool:
    return any(member["chapterId"] == chapter_id for row in rows.values() for member in row["members"])


def choose_primary(members: list[dict]) -> dict:
    def rank(member: dict) -> tuple:
        label = member.get("bookLabel") or ""
        book = (member.get("bookName") or "").lower()
        return (
            0 if "11-12" in book or "11–12" in book else 1,
            0 if label else 1,
            -member.get("questionCount", 0),
        )

    return sorted(members, key=rank)[0]


def preserved_manual(db, exam: str) -> list[dict]:
    current = db.exam_chapter_maps.find_one({"exam": exam}, {"rows": 1})
    if not current:
        return []
    kept = []
    for row in current.get("rows") or []:
        manual_members = [member for member in row.get("members") or [] if member.get("manual")]
        if manual_members:
            kept.append({**row, "members": manual_members})
    return kept


def apply_manual(rows: list[dict], manual_rows: list[dict]) -> list[dict]:
    by_key = {row["mapKey"]: row for row in rows}
    for source in manual_rows:
        row = by_key.get(source.get("mapKey"))
        if row is None:
            row = blank_row(
                source.get("mapKey"),
                source.get("chapterName") or "Chapter",
                source.get("subject") or "",
                source.get("standard") or "",
            )
            rows.append(row)
            by_key[row["mapKey"]] = row
        if source.get("visibilityManual"):
            row["teacherVisible"] = bool(source.get("teacherVisible"))
            row["needsReview"] = not row["teacherVisible"]
            row["visibilityManual"] = True
        for member in source["members"]:
            for other in rows:
                other["members"] = [item for item in other["members"] if item["chapterId"] != member["chapterId"]]
            if not any(item["chapterId"] == member["chapterId"] for item in row["members"]):
                row["members"].append(member)
    kept = []
    for row in rows:
        members = row.get("members") or []
        if not members:
            continue
        row["memberIds"] = [member["chapterId"] for member in members if member.get("chapterId")]
        row["questionCount"] = sum(int(member.get("questionCount") or 0) for member in members)
        row["bookLabels"] = sorted({member["bookLabel"] for member in members if member.get("bookLabel")})
        kept.append(row)
    return kept


if __name__ == "__main__":
    main()
