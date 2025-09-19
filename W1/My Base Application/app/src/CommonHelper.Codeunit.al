namespace christianbraeunlich.MyBaseApplication;

codeunit 70000 CommonHelper
{
    trigger OnRun()
    begin

    end;

    var
        SecondsCannotBeNegative: Label 'Seconds cannot be negative';

    procedure ConvertSecondsIntoMinutes(seconds: Integer): Decimal
    begin
        if seconds <= 0 then
            Error(SecondsCannotBeNegative);
        exit(seconds / 60);
    end;

}