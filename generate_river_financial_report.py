#!/usr/bin/env python3
"""Generate a comprehensive PDF report on River Financial findings."""

from datetime import datetime, timezone
from pathlib import Path

from fpdf import FPDF

OUTPUT_PATH = Path("/workspace/River_Financial_Findings_Report.pdf")
ARTIFACTS_PATH = Path("/opt/cursor/artifacts/River_Financial_Findings_Report.pdf")


class ReportPDF(FPDF):
    def header(self):
        self.set_font("Helvetica", "B", 10)
        self.set_text_color(80, 80, 80)
        self.cell(0, 8, "River Financial - Complete Findings Report", align="R", new_x="LMARGIN", new_y="NEXT")
        self.ln(2)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 10, f"Page {self.page_no()}", align="C")

    def section_title(self, title: str):
        self.ln(3)
        self.set_font("Helvetica", "B", 14)
        self.set_text_color(20, 60, 120)
        self.cell(0, 10, title, new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(20, 60, 120)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(4)

    def subsection_title(self, title: str):
        self.ln(2)
        self.set_font("Helvetica", "B", 12)
        self.set_text_color(40, 40, 40)
        self.cell(0, 8, title, new_x="LMARGIN", new_y="NEXT")
        self.ln(1)

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

    def label_value(self, label: str, value: str, label_width: int = 48):
        self.set_font("Helvetica", "B", 11)
        self.set_text_color(30, 30, 30)
        self.cell(label_width, 7, label)
        self.set_font("Helvetica", "", 11)
        self.multi_cell(0, 7, value)


def build_report() -> None:
    report_date = datetime.now(timezone.utc).strftime("%B %d, %Y at %H:%M UTC")

    pdf = ReportPDF()
    pdf.set_auto_page_break(auto=True, margin=20)
    pdf.add_page()

    pdf.set_font("Helvetica", "B", 24)
    pdf.set_text_color(15, 45, 90)
    pdf.cell(0, 14, "River Financial", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 14)
    pdf.set_text_color(60, 60, 60)
    pdf.cell(0, 8, "Complete Research Findings Report", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "I", 10)
    pdf.cell(0, 6, f"Report generated: {report_date}", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(8)

    pdf.section_title("1. Executive Summary")
    pdf.body_text(
        "This report documents all publicly available findings about River Financial (branded as "
        "River), a U.S.-based Bitcoin financial services company. Information was gathered from "
        "River's official website (river.com), support pages, help center documentation, and "
        "regulatory disclosure pages. The report covers company overview, products and services, "
        "website links, contact details, support hours, communication policies, and security notes."
    )

    pdf.section_title("2. Company Overview")
    pdf.label_value("Company name:", "River Financial Inc. (operating as River)")
    pdf.ln(2)
    pdf.label_value("Industry:", "Bitcoin financial services")
    pdf.ln(2)
    pdf.label_value("Mission:", "Building a trusted Bitcoin financial institution")
    pdf.ln(2)
    pdf.label_value("Headquarters:", "San Francisco, California, USA")
    pdf.ln(2)
    pdf.label_value("Mailing address:", "2261 Market Street Ste 22113\nSan Francisco, CA 94114")
    pdf.ln(4)
    pdf.body_text(
        "River positions itself as a U.S.-based team focused on Bitcoin investment, custody, "
        "banking-related services, and client support. The company emphasizes transparency "
        "(including Proof of Reserves), security, and regulatory compliance across multiple U.S. "
        "states."
    )

    pdf.section_title("3. Products and Services")
    pdf.body_text("Based on River's public website, the company offers the following:")
    pdf.bullet("Buy and Sell: Buy and sell Bitcoin instantly")
    pdf.bullet("Bitcoin Interest on Cash: Earn interest on cash balances, paid in Bitcoin (advertised rate: 3.30%)")
    pdf.bullet("Banking: Earn bitcoin while you bank")
    pdf.bullet("Zero-fee recurring buys: No fees on recurring Bitcoin purchases")
    pdf.bullet("Proof of Reserves: Transparency reporting on Bitcoin reserves")
    pdf.bullet("Send and Receive: Transfer and store Bitcoin")
    pdf.bullet("Learn: Educational content from basic to advanced Bitcoin concepts")
    pdf.bullet("Research: Reports and analysis on Bitcoin topics")
    pdf.bullet("Individual, Business, and Private Client account tiers")
    pdf.ln(2)

    pdf.section_title("4. Official Websites and Online Resources")
    pdf.subsection_title("Primary URLs")
    pdf.label_value("Main website:", "https://river.com/")
    pdf.ln(2)
    pdf.label_value("Support page:", "https://river.com/support")
    pdf.ln(2)
    pdf.label_value("Help center:", "https://support.river.com/")
    pdf.ln(2)
    pdf.label_value("Licenses & disclosures:", "https://river.com/legal/licenses")
    pdf.ln(2)
    pdf.label_value("Privacy policy:", "https://river.com/legal/privacy")
    pdf.ln(4)

    pdf.subsection_title("Additional Site Sections")
    pdf.bullet("Company information and mission: river.com (Company section)")
    pdf.bullet("Company financials: Available on the main website")
    pdf.bullet("Careers: Listed on the main website")
    pdf.bullet("Security information: How River protects client bitcoin")
    pdf.bullet("Announcements and newsletter: Company and industry updates")
    pdf.ln(2)

    pdf.section_title("5. Contact Information")
    pdf.subsection_title("Client Services")
    pdf.label_value("Email:", "support@river.com")
    pdf.ln(2)
    pdf.label_value("Phone:", "(888) 801-2586  |  Toll-free: 1 (888) 801-2586")
    pdf.ln(2)
    pdf.label_value("Mailing address:", "2261 Market Street Ste 22113\nSan Francisco, CA 94114")
    pdf.ln(4)

    pdf.subsection_title("How to Contact River")
    pdf.body_text(
        "River's Help Center is the first place to look for answers. If your question is not "
        "answered there, you can email Client Services at any time or call during business hours."
    )
    pdf.bullet("Email: Available 24/7 at support@river.com")
    pdf.bullet("Phone: Available during business hours at (888) 801-2586")
    pdf.bullet("Email follow-up: River states they will follow up within 24 hours")
    pdf.ln(2)

    pdf.section_title("6. Client Services Hours")
    pdf.body_text("Two slightly different schedules appear on River's public pages:")
    pdf.subsection_title("Help Center Schedule")
    pdf.bullet("Monday through Thursday: 9:00 AM - 8:00 PM EST")
    pdf.bullet("Friday: 9:00 AM - 6:00 PM EST")
    pdf.subsection_title("Support Page Schedule")
    pdf.bullet("Monday through Friday: 9:00 AM - 8:00 PM Eastern Time")
    pdf.ln(2)
    pdf.body_text(
        "Recommendation: Call during the help center hours listed above. Email support@river.com "
        "is available outside those hours."
    )

    pdf.section_title("7. How River Will Contact You")
    pdf.subsection_title("Email Communications")
    pdf.bullet("All official River emails are sent from the @river.com domain.")
    pdf.bullet(
        "River uses BIMI (Brand Indicators for Message Identification). Major providers "
        "(Google, Apple, Yahoo) may show River's verified logo or blue checkmark."
    )
    pdf.bullet("Support emails: Direct responses from Client Services team members")
    pdf.bullet("Security emails: Automated alerts for login activity or security changes")
    pdf.bullet("Transactional emails: Automated notices for account activity")
    pdf.ln(2)

    pdf.subsection_title("Phone Communications")
    pdf.body_text(
        "IMPORTANT: River states it will NEVER call you unsolicited. Any unexpected phone call "
        "claiming to be from River should be considered illegitimate. River does not initiate "
        "outbound sales or support calls to clients."
    )

    pdf.subsection_title("Text Messages")
    pdf.bullet("River may send automated SMS for security purposes (e.g., 2FA codes)")
    pdf.bullet("Security texts are one-way only and cannot receive replies")
    pdf.ln(2)

    pdf.section_title("8. Security and Fraud Prevention")
    pdf.bullet("Verify all emails come from @river.com before responding or clicking links")
    pdf.bullet("Do not trust unsolicited phone calls claiming to be River")
    pdf.bullet("If unsure about any message, email support@river.com to verify authenticity")
    pdf.bullet("Report suspected fraud to support@river.com or call (888) 801-2586 immediately")
    pdf.bullet("River's privacy policy directs security concerns to support@river.com")
    pdf.ln(2)

    pdf.section_title("9. Regulatory and Complaint Information")
    pdf.body_text(
        "River Financial Inc. is licensed and regulated as a money transmitter in multiple U.S. "
        "states. Regulatory disclosures are published at https://river.com/legal/licenses."
    )
    pdf.subsection_title("Complaint Process")
    pdf.bullet("First contact: support@river.com or (888) 801-2586")
    pdf.bullet("Online: https://river.com/support")
    pdf.bullet(
        "If unresolved, complaints may be escalated to the relevant state regulator "
        "(e.g., Connecticut Department of Banking, Maryland Office of Financial Regulation, "
        "Washington State Department of Financial Institutions), as listed on the licenses page."
    )
    pdf.ln(2)

    pdf.section_title("10. Quick Reference")
    pdf.set_font("Helvetica", "B", 10)
    pdf.set_fill_color(230, 240, 250)
    pdf.cell(55, 8, "Item", border=1, fill=True)
    pdf.cell(125, 8, "Details", border=1, fill=True, new_x="LMARGIN", new_y="NEXT")
    rows = [
        ("Website", "https://river.com/"),
        ("Support", "https://river.com/support"),
        ("Email", "support@river.com"),
        ("Phone", "(888) 801-2586"),
        ("Address", "2261 Market St Ste 22113, SF, CA 94114"),
        ("Hours (Help Center)", "Mon-Thu 9AM-8PM, Fri 9AM-6PM EST"),
        ("Hours (Support page)", "Mon-Fri 9AM-8PM Eastern"),
    ]
    pdf.set_font("Helvetica", "", 10)
    for label, value in rows:
        pdf.cell(55, 8, label, border=1)
        pdf.cell(125, 8, value, border=1, new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)

    pdf.section_title("11. Research Methodology")
    pdf.body_text(
        "Findings in this report were compiled through review of River Financial's publicly "
        "accessible web properties on July 31, 2026. No private databases, paid sources, or "
        "third-party directories were used. All contact details and policies should be verified "
        "on River's official website before use, as they may change over time."
    )

    pdf.section_title("12. Sources")
    pdf.bullet("https://river.com/")
    pdf.bullet("https://river.com/support")
    pdf.bullet("https://support.river.com/")
    pdf.bullet(
        "https://support.river.com/hc/en-us/articles/50055145238547-"
        "How-do-I-contact-River-and-how-will-River-contact-me"
    )
    pdf.bullet("https://river.com/legal/licenses")
    pdf.bullet("https://river.com/legal/privacy")
    pdf.ln(4)

    pdf.set_font("Helvetica", "I", 9)
    pdf.set_text_color(100, 100, 100)
    pdf.multi_cell(
        0,
        5,
        "Disclaimer: This report is for informational purposes only and is based on publicly "
        "available information at the time of preparation. It does not constitute financial, "
        "legal, or investment advice. Contact details, business hours, product offerings, and "
        "policies may change. Always verify current information directly with River Financial "
        "through their official channels before taking action.",
    )

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    pdf.output(str(OUTPUT_PATH))
    ARTIFACTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    pdf.output(str(ARTIFACTS_PATH))
    print(f"Report saved to: {OUTPUT_PATH}")
    print(f"Artifacts copy: {ARTIFACTS_PATH}")


if __name__ == "__main__":
    build_report()
