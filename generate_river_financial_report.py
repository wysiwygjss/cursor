#!/usr/bin/env python3
"""Generate a PDF report on River Financial contact and website findings."""

from datetime import datetime, timezone
from pathlib import Path

from fpdf import FPDF


OUTPUT_PATH = Path("/workspace/River_Financial_Report.pdf")


class ReportPDF(FPDF):
    def header(self):
        self.set_font("Helvetica", "B", 11)
        self.set_text_color(80, 80, 80)
        self.cell(0, 8, "River Financial - Research Report", align="R", new_x="LMARGIN", new_y="NEXT")
        self.ln(2)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 10, f"Page {self.page_no()}", align="C")

    def section_title(self, title: str):
        self.ln(4)
        self.set_font("Helvetica", "B", 14)
        self.set_text_color(20, 60, 120)
        self.cell(0, 10, title, new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(20, 60, 120)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(4)

    def body_text(self, text: str):
        self.set_font("Helvetica", "", 11)
        self.set_text_color(30, 30, 30)
        self.multi_cell(0, 6, text)
        self.ln(2)

    def bullet(self, text: str):
        self.set_font("Helvetica", "", 11)
        self.set_text_color(30, 30, 30)
        x = self.get_x()
        self.cell(6, 6, chr(149))
        self.multi_cell(0, 6, text)
        self.set_x(x)

    def label_value(self, label: str, value: str):
        self.set_font("Helvetica", "B", 11)
        self.set_text_color(30, 30, 30)
        self.cell(45, 7, label)
        self.set_font("Helvetica", "", 11)
        self.multi_cell(0, 7, value)


def build_report() -> None:
    report_date = datetime.now(timezone.utc).strftime("%B %d, %Y (UTC)")

    pdf = ReportPDF()
    pdf.set_auto_page_break(auto=True, margin=20)
    pdf.add_page()

    # Title block
    pdf.set_font("Helvetica", "B", 22)
    pdf.set_text_color(15, 45, 90)
    pdf.cell(0, 12, "River Financial", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 13)
    pdf.set_text_color(60, 60, 60)
    pdf.cell(0, 8, "Website & Contact Information Report", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "I", 10)
    pdf.cell(0, 6, f"Prepared: {report_date}", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(6)

    pdf.section_title("Executive Summary")
    pdf.body_text(
        "River Financial (operating as River) is a U.S.-based Bitcoin financial services "
        "company that offers Bitcoin investment, custody, and related services. This report "
        "summarizes publicly available website and contact information gathered from River's "
        "official web properties and help center documentation."
    )

    pdf.section_title("Company Overview")
    pdf.bullet("Legal entity: River Financial Inc.")
    pdf.bullet("Industry: Bitcoin financial services")
    pdf.bullet("Focus: Bitcoin investment, custody, and client support")
    pdf.bullet("Headquarters mailing address: 2261 Market Street Ste 22113, San Francisco, CA 94114")
    pdf.ln(2)

    pdf.section_title("Official Websites")
    pdf.label_value("Main website:", "https://river.com/")
    pdf.ln(2)
    pdf.label_value("Support page:", "https://river.com/support")
    pdf.ln(2)
    pdf.label_value("Help center:", "https://support.river.com/")
    pdf.ln(2)
    pdf.label_value("Licenses & disclosures:", "https://river.com/legal/licenses")
    pdf.ln(4)

    pdf.section_title("Contact Information")
    pdf.label_value("Email:", "support@river.com")
    pdf.ln(2)
    pdf.label_value("Phone:", "(888) 801-2586")
    pdf.ln(2)
    pdf.label_value("Mailing address:", "2261 Market Street Ste 22113\nSan Francisco, CA 94114")
    pdf.ln(4)

    pdf.section_title("Client Services Hours")
    pdf.body_text("According to River's help center and support pages:")
    pdf.bullet("Monday through Thursday: 9:00 AM - 8:00 PM EST")
    pdf.bullet("Friday: 9:00 AM - 6:00 PM EST")
    pdf.bullet("Support page also lists Monday-Friday: 9:00 AM - 8:00 PM Eastern Time")
    pdf.ln(2)

    pdf.section_title("How to Reach Support")
    pdf.body_text(
        "River's Help Center contains answers to frequently asked questions. If you cannot "
        "find an answer there, you may contact Client Services by email at any time or by "
        "phone during business hours. Email responses are typically followed up within 24 hours."
    )

    pdf.section_title("Security & Communication Notes")
    pdf.bullet("Official River emails are sent from the @river.com domain.")
    pdf.bullet(
        "River uses BIMI (Brand Indicators for Message Identification); major email providers "
        "may display River's verified logo or a blue checkmark next to authentic emails."
    )
    pdf.bullet(
        "River states it will never call you unsolicited. Any unexpected call claiming to be "
        "from River should be treated as illegitimate."
    )
    pdf.bullet(
        "River may send automated text messages for security purposes (e.g., two-factor "
        "authentication codes). These are one-way and cannot receive replies."
    )
    pdf.bullet(
        "If you receive a suspicious message or email, contact support@river.com to verify "
        "its authenticity."
    )
    pdf.ln(2)

    pdf.section_title("Sources")
    pdf.bullet("https://river.com/")
    pdf.bullet("https://river.com/support")
    pdf.bullet(
        "https://support.river.com/hc/en-us/articles/50055145238547-"
        "How-do-I-contact-River-and-how-will-River-contact-me"
    )
    pdf.bullet("https://river.com/legal/licenses")
    pdf.ln(4)

    pdf.set_font("Helvetica", "I", 9)
    pdf.set_text_color(100, 100, 100)
    pdf.multi_cell(
        0,
        5,
        "Disclaimer: This report is based on publicly available information at the time of "
        "preparation. Contact details, hours, and policies may change. Verify current "
        "information on River's official website before taking action.",
    )

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    pdf.output(str(OUTPUT_PATH))
    print(f"Report saved to: {OUTPUT_PATH}")


if __name__ == "__main__":
    build_report()
