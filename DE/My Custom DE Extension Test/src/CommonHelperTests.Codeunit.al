namespace christianbraeunlich.MyCustomDEExtension.Tests;

using christianbraeunlich.MyCustomDEExtension;
using System.TestLibraries.Utilities;

codeunit 72900 ClientRequestsTests
{
    Subtype = Test;

    trigger OnRun()
    begin

    end;

    var
        Assert: Codeunit "Library Assert";

    [Test]
    procedure TestConvertSecondsToMinutes()
    var
        clientRequests: Codeunit ClientRequests;
    begin
        Assert.AreEqual('Mo', clientRequests.WeekdayAbbreviation(1), 'Monday should be Mo');
    end;

    [Test]
    procedure TestDienstag()
    var
        clientRequests: Codeunit ClientRequests;
    begin
        Assert.AreEqual('Di', clientRequests.WeekdayAbbreviation(2), 'Dienstag should be Di');
    end;

}